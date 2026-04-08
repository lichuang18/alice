# SPDX-License-Identifier: GPL-2.0
obj-m += cf2fs.o

cf2fs-y		:= dir.o file.o inode.o namei.o hash.o super.o inline.o
cf2fs-y		+= checkpoint.o gc.o data.o node.o segment.o recovery.o
cf2fs-y		+= shrinker.o extent_cache.o sysfs.o compress.o
cf2fs-y		+= compress.o xattr.o acl.o verity.o
cf2fs-$(CONFIG_F2FS_STAT_FS) += debug.o
cf2fs-$(CONFIG_F2FS_FS_XATTR) += xattr.o
cf2fs-$(CONFIG_F2FS_FS_POSIX_ACL) += acl.o
cf2fs-$(CONFIG_FS_VERITY) += verity.o
cf2fs-$(CONFIG_F2FS_FS_COMPRESSION) += compress.o
cf2fs-$(CONFIG_F2FS_IOSTAT) += iostat.o
EXTRA_CFLAGS += -I$(PWD)

default:
	$(MAKE) -C /lib/modules/$(shell uname -r)/build M=$(shell pwd) modules

clean:
	$(MAKE) -C /lib/modules/$(shell uname -r)/build M=$(shell pwd) clean
