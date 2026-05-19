
# Windows-Laptop-Mode-Watcher

A script that checks when a windows 2-in-1 laptop fold up into tablet mode and then does some action based on entering or exiting tablet mode. Currently it disables all windhawk mods when entering, and re-enable them when exiting.


## Author

- [Brend Vanhooren (A.K.A. Ratsmacker9)](https://github.com/Ratsmacker9)


## Documentation

The "LaptopModeWatcher.ps1 script works by creating a Register-WMIEvent that triggers when a value of a key is changes in the "HKLM:\SYSTEM\\CurrentControlSet\\Control\\PriorityControl" directory in the registry. A changing value means that the laptop is either entering or exiting tablet mode. The script only has to be run ones on to keep the event live. It will then trigger instantly when the event happens.

To run the script manualy for testing (see all logs in color and real time) and create/register the event enter the full file path or navigate to the file location and run the script. The script will automaticly unregister an already existing event so feel free to test as many times as you want.
```powershell
#Run the script:
C:\Users\brend\OneDrive\Downloads\laptopWatcherLog.ps1

#Or
cd C:\Users\brend\OneDrive\Downloads\
laptopWatcherLog.ps1
```

To stop/unregister the event manualy, run the following commands:
```powershell
#Show all running events:
Get-EventSubscriber

#Stop an event:
Unregister-Event -SourceIdentifier "YourEventName"

#For this event it should be:
Unregister-Event -SourceIdentifier "TabletModeWatch"
```


## Deployment

To use this script you need to run it automaticly using Task Scheduler

I recommend placing the script in the Powershell Scripts folder (eg. C:\Users\username\Documents\Powershell\Scripts\SelfMade\) and making the subfolder ScriptData.
If you do not place it here you will need to change the script.
```
SelfMade/
├── ScriptData/
│   ├── LaptopModeDebug.log
│   └── windhawk-registry-keys.json
└── LaptopModeWatcher.ps1
```
Open Windows Task Scheduler and click "Create Task". Change the following settings.

- Add Name and Description
- Run with highest privileges
- I set "Configure for:" to Windows 10 (not sure this matters)
- Hidden
- Trigger → New: Begin task: At login
- Action → New: Program: "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" and add the script location to "Add arguments"
- Uncheck "Start the task only if the computer is on AC power"
- Uncheck "Stop the task if it runs longer than:"


