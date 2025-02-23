#!/bin/bash

# Copyright (c) 2022, Matthias Kruk

# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
#
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS
# IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
# THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
# PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR
# CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
# EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
# PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
# PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
# LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
# NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
# SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

_add_selection() {
	local name="$1"
	local value="$2"

	case "$name" in
		"package")
			packages+=("$value")
			;;
		"group")
			groups+=("$value")
			;;
		*)
			log_error "Invalid name: $name"
			return 1
			;;
	esac

	return 0
}

target_init() {
	local configdir="$1"
	local distro="$2"

	local target
	local -i err

	err=0

	if ! target=$(mktemp --directory); then
		return 1
	fi

	if ! mkdir -m 755 "$target"/dev               ||
	   ! mknod -m 600 "$target"/dev/console c 5 1 ||
	   ! mknod -m 600 "$target"/dev/initctl p     ||
	   ! mknod -m 666 "$target"/dev/full c 1 7    ||
	   ! mknod -m 666 "$target"/dev/null c 1 3    ||
	   ! mknod -m 666 "$target"/dev/ptmx c 5 2    ||
	   ! mknod -m 666 "$target"/dev/random c 1 8  ||
	   ! mknod -m 666 "$target"/dev/tty c 5 0     ||
	   ! mknod -m 666 "$target"/dev/tty0 c 4 0    ||
	   ! mknod -m 666 "$target"/dev/urandom c 1 9 ||
	   ! mknod -m 666 "$target"/dev/zero c 1 5; then
		log_error "Could not prepare target $target"
		err=1

	elif ! mkdir -p "$target/etc/dnf" "$target/etc/yum.repos.d"; then
		log_error "Could not create target dnf directory"
		err=1

	elif ! cp "$configdir/$distro/dnf.conf" "$target/etc/dnf/stuffer.conf"; then
		log_error "Could not copy dnf.conf of $distro to $target"
		err=1

	elif ! cp "$configdir/$distro/stuffer.repo" "$target/etc/yum.repos.d/."; then
		log_error "Could not copy stuffer.repo of $distro to target"
		err=1

	elif ! mkdir -p "$target/etc/sysconfig"                         ||
	     ! echo "NETWORKING=yes" >> "$target/etc/sysconfig/network" ||
	     ! echo "HOSTNAME=localhost.localdomain" >> "$target/etc/sysconfig/network"; then
		log_error "Could not write to $target/etc/sysconfig/network"
		err=1
	fi

	if (( err != 0 )); then
		if ! rm -rf "$target"; then
			log_warn "Could not clean up $target"
		fi
	else
		echo "$target"
	fi

	return "$err"
}

get_releasever() {
	local conf="$1"

	local releasever

#	if ! releasever=$(grep -m 1 -oP '^releasever[ ]*=[ ]*\K' "$conf"); then
        if ! releasever=$(grep -m 1 '^releasever=' "$conf" | sed 's/releasever=//'); then
		log_error "Could not get releasever from $conf"
		return 1
	fi

	echo "$releasever"
	return 0
}

target_install_packages() {
	local target="$1"
	local packages=("${@:2}")

	local config
	local releasever

	config="$target/etc/dnf/stuffer.conf"
	if ! releasever=$(get_releasever "$config"); then
		return 1
	fi

	if (( ${#packages[@]} > 0 )); then
		if ! dnf --config "$config"                       \
		         --releasever="$releasever"               \
		         --installroot="$target"                  \
		         --setopt="tsflags=nodocs"                \
		         --setopt="group_package_types=mandatory" \
		         -y install "${packages[@]}"; then
			log_error "Could not install all packages"
			return 1
		fi
	fi

	return 0
}

target_install_groups() {
	local target="$1"
	local groups=("${@:2}")

	local config
	local releasever

	config="$target/etc/dnf/stuffer.conf"
	if ! releasever=$(get_releasever "$config"); then
		return 1
	fi

	if (( ${#groups[@]} > 0 )); then
		if ! dnf --config "$config"                       \
		         --releasever="$releasever"               \
		         --installroot="$target"                  \
		         --setopt="tsflags=nodocs"                \
		         --setopt="group_package_types=mandatory" \
		         -y groupinstall "${groups[@]}"; then
			log_error "Could not install all groups"
			return 1
		fi
	fi

	return 0
}

convert_rpmdb() (
	local root="$1"

	if ! chroot "$root" rpmdb --rebuilddb; then
		return 1
	fi

	return 0
)

target_cleanup() {
	local target="$1"

	local config
	local -i releasever

	config="$target/etc/dnf/stuffer.conf"
	if ! releasever=$(get_releasever "$config"); then
		return 1
	fi

	if ! dnf -c "$config" --installroot="$target" -y clean all; then
		log_error "Could not clean up dnf cache in $target"
		return 1
	fi

	if (( releasever <= 8 )); then
		# On RHEL 8 and earlier, rpm uses the bdb backend, but newer
		# rpm versions (which we're very likely using) use sqlite.
		# Either rpm version can only read the other backend, so we
		# have to use the target's rpmdb command to rebuild the db.
		if ! convert_rpmdb "$target"; then
			return 1
		fi
	fi

	if ! rm -rf "$target"/usr/{{lib,share}/locale,{lib,lib64}/gconv,bin/localedef,sbin/build-locale-archive} ||
	   ! rm -rf "$target"/usr/share/{man,doc,info,gnome/help}                                                ||
	   ! rm -rf "$target"/usr/share/cracklib                                                                 ||
	   ! rm -rf "$target"/usr/share/i18n                                                                     ||
	   ! rm -rf "$target"/var/cache/yum                                                                      ||
	   ! mkdir -p --mode=0755 "$target"/var/cache/yum                                                        ||
	   ! rm -rf "$target"/sbin/sln                                                                           ||
	   ! rm -rf "$target"/etc/ld.so.cache "$target"/var/cache/ldconfig                                       ||
	   ! mkdir -p --mode=0755 "$target"/var/cache/ldconfig                                                   ||
	   ! rm -f "$target/etc/dnf/stuffer.conf"                                                                ||
	   ! rm -f "$target/etc/yum.repos.d/stuffer.repo"; then
		log_error "Could not clean up $target"
		return 1
	fi

	return 0
}

target_make_tag() {
	local target="$1"

	local releasefiles
	local releasefile
	local old_version_regex
	local new_version_regex

	releasefiles=(
		"$target/etc/miraclelinux-release"
		"$target/etc/asianux-release"
		"$target/etc/system-release"
	)
	old_version_regex='([0-9]+) SP([0-9]+)'
	new_version_regex='([0-9]+(|\.[0-9]+))'

	for releasefile in "${releasefiles[@]}"; do
		local content

		if ! content=$(cat "$releasefile" 2>/dev/null); then
			continue
		fi

		if [[ "$content" =~ $old_version_regex ]]; then
			echo "${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
			return 0
		fi

		if [[ "$content" =~ $new_version_regex ]]; then
			echo "${BASH_REMATCH[1]}"
			return 0
		fi
	done

	return 1
}

generate_docker_image() {
	local configdir="$1"
	local distro="$2"
	local name="$3"
	local version="$4"
	local -n install_packages="$5"
	local -n install_groups="$6"

	local target
	local -i err

	err=0

	if ! target=$(target_init "$configdir" "$distro"); then
		return 1

	elif ! target_install_groups "$target" "${install_groups[@]}"; then
		err=1

	elif ! target_install_packages "$target" "${install_packages[@]}"; then
		err=1

	elif ! target_cleanup "$target"; then
		err=1

	else
		if [[ -z "$version" ]] &&
		   ! version=$(target_make_tag "$target"); then
			log_warn "Could not determine version of target. Using timestamp."
			version=$(date +"%s")
		fi

		if ! tar --numeric-owner -c -C "$target" . | docker import - "$name:$version"; then
			log_error "Could not import docker image"
			err=1
		fi

		if ! docker run --rm "$name:$version" /usr/bin/true; then
			log_error "Generated image could not be started"
			err=1
		fi
	fi

	if ! rm -rf "$target"; then
		log_warn "Could not clean up $target"
	fi

	return "$err"
}

main() {
	local packages
	local groups
	local config
	local name
	local version
	local distro

	packages=()
	groups=()

	opt_add_arg "p" "package"    "v"  ""             "Add package to selection"    '' _add_selection
	opt_add_arg "g" "group"      "v"  ""             "Add group to selection"      '' _add_selection
	opt_add_arg "V" "version"    "v"  "latest"       "Version of the new image"
	opt_add_arg "n" "name"       "rv" ""             "Name of the new image"
	opt_add_arg "c" "config"     "v"  "/etc/stuffer" "Path to distro configurations"
	opt_add_arg "d" "distro"     "rv" ""             "The distribution to install"

	if ! opt_parse "$@"; then
		return 1
	fi

	if (( ${#groups[@]} == 0 )); then
		groups+=("Core")
	fi

	name=$(opt_get "name")
	version=$(opt_get "version")
	distro=$(opt_get "distro")
	config=$(opt_get "config")

	if ! generate_docker_image "$config" "$distro" "$name" "$version" packages groups; then
		return 1
	fi

	return 0
}

{
	if ! . toolbox.sh; then
		exit 1
	fi

	if ! include "log" "opt"; then
		exit 1
	fi

	main "$@"
	exit "$?"
}
