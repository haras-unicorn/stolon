# Options

<!-- markdownlint-disable MD013 -->

## stolon\.enable

Put the whole system on one disk\. The disk is encrypted and compressed, the
system starts from a clean slate on every boot and only keeps what is listed
under `stolon.keep`, old Nix garbage is collected daily, and `stolon-backup` and
`stolon-restore` are installed to move what is kept to another drive\.

The disk is set up with the `disko` scripts in `config.system.build`\. Decide
what to keep before that, because every kept directory gets its own place on the
disk when it is set up\.

_Type:_ boolean

_Default:_

```nix
false
```

## stolon\.backup\.maximumCompression

Make backups as small as possible\. It takes longer\. Backups are always
compressed and encrypted, and this only decides how hard they are compressed\.

_Type:_ boolean

_Default:_

```nix
false
```

## stolon\.bootSize

How much room the boot partition gets\. The default is plenty\. A bigger one
only helps if you keep many generations of kernels\.

_Type:_ string

_Default:_

```nix
"1G"
```

## stolon\.compression\.enable

Make files take less room on the disk\. It costs very little speed\. Turn this
off only if your disk or processor is slow\.

_Type:_ boolean

_Default:_

```nix
true
```

## stolon\.compression\.level

How hard to compress, from 1 to 15\. A higher number saves more room and is
slower\.

_Type:_ integer between 1 and 15 (both inclusive)

_Default:_

```nix
3
```

## stolon\.device

The disk to put the system on\. Everything on it is erased when it is set up\.
Use a path from `/dev/disk/by-id`, because it does not change when disks are
plugged in a different order\.

_Type:_ string

_Example:_

```nix
"/dev/disk/by-id/nvme-Samsung_SSD_980_PRO_1TB_S5GXNX0T000000"
```

## stolon\.encryption\.enable

Encrypt the disk, so nobody can read it without the passphrase\. Turn this off
only if encryption makes your disk too slow\.

_Type:_ boolean

_Default:_

```nix
true
```

## stolon\.encryption\.passwordFile

A file with the passphrase to set the disk up with, so that setting it up does
not stop to ask\. It is not used to unlock the disk when the system starts\.
Leave it empty to be asked\.

The file holds the passphrase itself, so keep it out of git\. Make it right
before setting the disk up, in `/run`, which is gone after a reboot\. This
command asks for the passphrase without showing it or saving it in the shell
history, and leaves out the newline that would otherwise become part of the
passphrase:

```sh
(umask 077; read -rsp 'Passphrase: ' p && printf '%s' "$p" > /run/password)
```

_Type:_ null or string

_Default:_

```nix
null
```

_Example:_

```nix
"/run/password"
```

## stolon\.gc\.enable

Free the room taken by old Nix generations and by projects you stopped working
on, once a day\.

_Type:_ boolean

_Default:_

```nix
true
```

## stolon\.gc\.retentionDays

How many days to keep old generations\. The direnv environments of a project are
also removed once its git history has not moved for this many days\.

_Type:_ positive integer, meaning >0

_Default:_

```nix
14
```

## stolon\.keep\.databases

Folders of databases\. They are kept like `stolon.keep.directories`, and are
also set up so that they do not slow down as the many small writes of a database
fragment them\. The price is that the files in them are not compressed\.

_Type:_ list of absolute path without a trailing slash

_Default:_

```nix
[ ]
```

_Example:_

```nix
[
  "/var/lib/postgresql"
  "/var/lib/mysql"
]
```

## stolon\.keep\.directories

Folders to keep\. Everything outside of the kept folders is thrown away on every
boot, so list everything you would be sad to lose, such as your documents, your
SSH keys and the data of your services\. Folders in a home keep the owner of
that home\.

The system’s own folders (`/var/lib/nixos`, `/var/log`) are always kept, and so
is `/etc/machine-id`\.

_Type:_ list of absolute path without a trailing slash

_Default:_

```nix
[ ]
```

_Example:_

```nix
[
  "/home/alice/Documents"
  "/home/alice/.ssh"
  "/srv/photos"
]
```

## stolon\.keep\.files

Single files to keep\. Use `stolon.keep.directories` for folders\.

_Type:_ list of absolute path without a trailing slash

_Default:_

```nix
[ ]
```

_Example:_

```nix
[
  "/home/alice/.bash_history"
]
```

## stolon\.keep\.vms

Folders of virtual machine disks\. They are kept like `stolon.keep.directories`,
and are also set up so that they do not slow down as the many small writes of a
virtual machine fragment them\. The price is that the files in them are not
compressed\.

_Type:_ list of absolute path without a trailing slash

_Default:_

```nix
[ ]
```

_Example:_

```nix
[
  "/var/lib/libvirt/images"
]
```

## stolon\.trim\.enable

Tell the disk regularly which parts are free, so an SSD stays fast\. Someone who
gets hold of the disk can see which parts are free, but not what is in the
rest\. Turn this off on hard drives\.

_Type:_ boolean

_Default:_

```nix
true
```
