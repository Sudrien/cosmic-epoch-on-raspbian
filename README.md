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

Reboot and test now. In worse case, did you know you can access multiple terminals with ctrl+alt+F2 through F6 when you think you can't get out of graphical mode? 

- You may run build-cosmic-sysext.sh now. It usses sudo beforehand for debian package install, and after compilation for install. If you change you mind on using --no-sysext after sleeping on it, cancel at the second prompt. sysext keeps you from updating a system while it's active.

- So, you successfully logged in to cosmic via nwg-hello. You used the --no-sysext so it's a permanent install. GDBus.Error:org.freedesktop.PolicyKit1.Error.Failed: An authentication agent already exists for the given subject

/etc/xdg/autostart/polkit-mate-authentication-agent-1.desktop
/etc/xdg/autostart/lxpolkit.desktop

You are looking for the `NotShowIn=` line and slapping `COSMIC;` at the end, in both files. 

- now it's time to change the greeter. 

> usermod -a -G video cosmic-greeter

/etc/greetd/config.toml
```
[terminal]
vt = 7
[default_session]
command = "/usr/bin/dbus-run-session /usr/bin/cosmic-comp /usr/bin/cosmic-greeter >>/tmp/cosmic-greeter.log 2>&1"
# i'm sure this can be changed somehow, but yes, different user
user = "cosmic-greeter"
```

