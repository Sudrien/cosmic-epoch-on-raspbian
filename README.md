This builds in ~/Projects/cosmic-epoch

It has the (TODO: OPTION) to build with systemd-sysext if non-committal - you'll still probably want to switch form the default raspberry pi greeter for session selection. 

This was tested in Trixie. This is stealing & debugging code via Claude, and therefore presumably unlicensable.


- how to assure the patch is happening?
- cosmic-greeter has a special install, greetd somthing somthing



NOTES:

- set up `greetd` first. You need a proper login screen to select sessions. You will probably update this later to cosmic-greeter, which still uses greetd, so you might as well make the greetd switch while other things are known working. 

> sudo apt install greetd nwg-hello

> sudo usermod -aG video,render _greetd

/etc/greetd/config.toml
```
[terminal]
vt = 7
[default_session]
command = "labwc -C /etc/greetd/labwc -s nwg-hello"
user = "_greetd"
```
> sudo systemctl disable lightdm

> sudo systemctl enable greetd


