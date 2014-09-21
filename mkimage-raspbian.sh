#!/usr/bin/env bash
set -e

dir="wheezy-chroot"
rootfsDir="wheezy-chroot"
tarFile="raspbian.2014.09.09.tar.xz"
( set -x; mkdir -p "$rootfsDir" )

(
	set -x
	debootstrap --no-check-gpg --arch=armhf --variant=minbase wheezy "$rootfsDir" http://archive.raspbian.org/raspbian
)

# now for some Docker-specific tweaks

# prevent init scripts from running during install/update
echo >&2 "+ echo exit 101 > '$rootfsDir/usr/sbin/policy-rc.d'"
cat > "$rootfsDir/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh

# For most Docker users, "apt-get install" only happens during "docker build",
# where starting services doesn't work and often fails in humorous ways. This
# prevents those failures by stopping the services from attempting to start.

exit 101
EOF
chmod +x "$rootfsDir/usr/sbin/policy-rc.d"

# prevent upstart scripts from running during install/update
(
	set -x
	chroot "$rootfsDir" dpkg-divert --local --rename --add /sbin/initctl
	cp -a "$rootfsDir/usr/sbin/policy-rc.d" "$rootfsDir/sbin/initctl"
	sed -i 's/^exit.*/exit 0/' "$rootfsDir/sbin/initctl"
)

# shrink a little, since apt makes us cache-fat (wheezy: ~157.5MB vs ~120MB)
( set -x; chroot "$rootfsDir" apt-get clean )


if [ -d "$rootfsDir/etc/apt/apt.conf.d" ]; then
	# _keep_ us lean by effectively running "apt-get clean" after every install
	aptGetClean='"rm -f /var/cache/apt/archives/*.deb /var/cache/apt/archives/partial/*.deb /var/cache/apt/*.bin || true";'
	echo >&2 "+ cat > '$rootfsDir/etc/apt/apt.conf.d/docker-clean'"
	cat > "$rootfsDir/etc/apt/apt.conf.d/docker-clean" <<-EOF
		# Since for most Docker users, package installs happen in "docker build" steps,
		# they essentially become individual layers due to the way Docker handles
		# layering, especially using CoW filesystems.  What this means for us is that
		# the caches that APT keeps end up just wasting space in those layers, making
		# our layers unnecessarily large (especially since we'll normally never use
		# these caches again and will instead just "docker build" again and make a brand
		# new image).

		# Ideally, these would just be invoking "apt-get clean", but in our testing,
		# that ended up being cyclic and we got stuck on APT's lock, so we get this fun
		# creation that's essentially just "apt-get clean".
		DPkg::Post-Invoke { ${aptGetClean} };
		APT::Update::Post-Invoke { ${aptGetClean} };

		Dir::Cache::pkgcache "";
		Dir::Cache::srcpkgcache "";

		# Note that we do realize this isn't the ideal way to do this, and are always
		# open to better suggestions (https://github.com/docker/docker/issues).
	EOF

	# remove apt-cache translations for fast "apt-get update"
	echo >&2 "+ echo Acquire::Languages 'none' > '$rootfsDir/etc/apt/apt.conf.d/docker-no-languages'"
	cat > "$rootfsDir/etc/apt/apt.conf.d/docker-no-languages" <<-'EOF'
	# In Docker, we don't often need the "Translations" files, so we're just wasting
	# time and space by downloading them, and this inhibits that.  For users that do
	# need them, it's a simple matter to delete this file and "apt-get update". :)

	Acquire::Languages "none";
	EOF

	echo >&2 "+ echo Acquire::GzipIndexes 'true' > '$rootfsDir/etc/apt/apt.conf.d/docker-gzip-indexes'"
	cat > "$rootfsDir/etc/apt/apt.conf.d/docker-gzip-indexes" <<-'EOF'
	# Since Docker users using "RUN apt-get update && apt-get install -y ..." in
	# their Dockerfiles don't go delete the lists files afterwards, we want them to
	# be as small as possible on-disk, so we explicitly request "gz" versions and
	# tell Apt to keep them gzipped on-disk.

	# For comparison, an "apt-get update" layer without this on a pristine
	# "debian:wheezy" base image was "29.88 MB", where with this it was only
	# "8.273 MB".

	Acquire::GzipIndexes "true";
	Acquire::CompressionTypes::Order:: "gz";
	EOF
fi


(
	set -x
	
	# make sure we're fully up-to-date
	chroot "$rootfsDir" /bin/bash -c 'apt-get update && apt-get dist-upgrade -y'
	
	# delete all the apt list files since they're big and get stale quickly
	rm -rf "$rootfsDir/var/lib/apt/lists"/*
	# this forces "apt-get update" in dependent images, which is also good
	
	mkdir "$rootfsDir/var/lib/apt/lists/partial" # Lucid... "E: Lists directory /var/lib/apt/lists/partial is missing."
)

# Docker mounts tmpfs at /dev and procfs at /proc so we can remove them
rm -rf "$rootfsDir/dev" "$rootfsDir/proc"
mkdir -p "$rootfsDir/dev" "$rootfsDir/proc"

# make sure /etc/resolv.conf has something useful in it
mkdir -p "$rootfsDir/etc"
cat > "$rootfsDir/etc/resolv.conf" <<'EOF'
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF

(
	set -x
	tar --remove-files --numeric-owner -cJvf "$tarFile" -C "$rootfsDir" .
)

#( set -x; rm -rf "$rootfsDir" )
