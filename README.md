# personal-backup-system

## How to setup a new client

### Server
* `cd /root/bin; /root/bin/provision_new_duplicacy_client_on_server.bash new_client_hostname server_or_desktop ed25519_or_rsa`
* Copy paste the client private key as you'll need it on the client

### Client

This assumes we're using Chef to provision the client

Add a section to the client's `node.json`

```json
{
  "duplicacy_backup": {
    "ssh_private_key": "PASTE THE SSH PRIVATE KEY MATERIAL GOES HERE",
    "known_hosts": "[mina.cementhorizon.com]:50000,[192.168.0.1]:50000,[173.228.105.201]:50000 ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBIGWf1vGa6KCR8fKk8X3Fk2rgsjpra4X7pmsNxC90ENSEPjOdVZqGOVo5w6QmcKbx7KHlylypqrAbTZ3nx0mQj0=\n[mina.cementhorizon.com]:50000,[192.168.0.1]:50000,[173.228.105.201]:50000 ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC3Jd6KVshNXWyysvM8mkOXVepp896C5Ft4+yrSkFKSYQWSOu7qpOeUD2JknfvI3cB5MaBy/uI9I2xgmiQFMmVPpdIPlGkotKTekRdnc/2vbHRylS4nTDlhxrdgEVZ6gp2dzV/xSTtUPHw6EhbPTQXfqbvmrZuFBxdbZyYft0j95+GNe9njlgGasK3NbouL9rDuB7qrBG5vAPtowngI4YXCNdi9LSSxfhoVU6Xmxeew+Kq4vBO5fpOlSEOl0r4uBxZuVM6rl+vSEyIT3sdcwdSLMYYDz+TE6bhcBDLIA/6S6poZ+tjd4uakcp+HkzlJ0FyZTTwistXeLLQfCp8/DAFZ\ndorothy.kixy.win,173.228.105.201 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILe/FH0PWGZMSojDuOZLymU2m5q7cF9J+d63hv0mcqFC\ndorothy.kixy.win,173.228.105.201 ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCzkFCXNAvU0IV748aavM4r47sGTMFtJunJqKibMBfrvo1jDbfZhzFTU1Jd86ut21c5eAoOpcJmBlMCt/mpo4+JvhXmp17M5oXoTfK82pB5hvsuP66x6vmHroxdoMY8yUYfZq/IDPvgmGdBIcw2jubEmvR4G/IkeVBgCBf8TXEZRHeEY5nn322sdlseGWes7empXebngnf8EPtbS8KSGp54KGF+rFZuVSiRP4BBM40GTZQJ/sEvmZmeETf7vaksEKx5DYFHm5jXkR3CwJtymHVzT9+jAOPZYVwH8E8tx2sKsHr2TwFiT/gBI0X46zij7cThUOOrISfFYFilVH/OEACj\ndorothy.kixy.win,173.228.105.201 ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBJHyc0+gqtQrSzblCGa1ES+8hBWYKrHzckrcA3fuq3l6AFpXrD8Dfx0dxbolI+8Gv3GvbEphCNA32ryWf5tNhU4=\n",
    "storage_password": "CREATE A DUPLICACY STORAGE PASSWORD AND STORE IT IN BITWARDEN",
    "sftp_backup_server": {
      "fqdn": "dorothy.kixy.win",
      "ssh_port": 22
    }
  }
}
```

or use

```json
    "sftp_backup_server": {
      "fqdn": "mina.cementhorizona.com",
      "ssh_port": 50000
    }
```

* Add 

## TODO

### Upgrade and check chunks

* Upgrade all clients to 2.6.2 or newer, then run check --chunks to see
  if there is corruption https://github.com/gilbertchen/duplicacy/releases/tag/v2.6.2
  * carol : binary already upgraded
  * flora
  * eva : binary upgraded. I've not been able to check chunks as the ban
    bandwidth requirements are too high. I guess I need to try some other
    method
  * arcade
  * dorothy : binary was already upgraded. chunk check in progress 9/21
  * kestrel
  * arcade-win
  * brenda : done (this was first installed at 2.7.2)

### RSA

If we encrypted with RSA then every client could encrypt to the same key
and we would get deduplication and save space.

Downside is that clients couldn't do their own restore

### Clients write-only, server does pruning

If we can set SFTP permissions such that users can create new files but
not modify or delete existing files and we setup a routine prune run on
the server itself, then we get protection from ransomware that
deletes/encrypts files on the client, then goes and deletes the backup.

I'm not sure if duplicacy works with SFTP set such that users can't
change/rename/modify files.