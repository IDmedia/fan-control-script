<div align="center">
  <img src="extras/logo.png" width="250" alt="logo">
</div>


# Unraid Fan Control Script
This Bash script enables automatic adjustment of fan speed in Unraid based on the temperature of your hard drives in the array. You can customize the disks to include or exclude, as well as adjust temperature settings for different fan control scenarios.


## Prerequisites

Before using this script, make sure you have completed the following steps:

1. Enable Manual Fan Speed Control in Unraid:
Edit the "/boot/syslinux/syslinux.cfg" file and change the line:
```
append initrd=/bzroot
```
to:
```
append initrd=/bzroot acpi_enforce_resources=lax
```
2. Set BIOS Settings:
Set the PWM headers you want to control to 100%/255 and mode to PWM in your BIOS.


## Usage Tips
To identify fan headers, use the command sensors -uA.
Utilize pwmconfig to find the correct fan header.
Test PWM pins from the terminal using attributes like pwm[1-5], pwm[1-5]_enable, and pwm[1-5]_mode.


## Usage:

Utilize the `User Scripts` plugin to set up a new script.

* Name: Fan Control Script
* Description: Automatically adjust fan speed based on array temperature.
* Schedule: Custom -> `*/5 * * * *`
* Script: Contents of fan_speed_control.sh


# Configuration

Adjust the following parameters in the script according to your preferences:

`MIN_PWM`: Minimum PWM value when all disks are spun down.  
`LOW_PWM` and `HIGH_PWM`: PWM values for calculating new values between LOW_TEMP and HIGH_TEMP temperatures.  
`MAX_PWM`: Maximum PWM value for setting the fan to max speed during parity or high disk temperatures.  
`LOW_TEMP` and `HIGH_TEMP`: Temperature range for automatic fan adjustment.  
`MAX_TEMP`: Maximum temperature threshold for sending alerts.  
`INCLUDE_DISK_TYPE_*`: Specify which disk types to include (1) or exclude (0).  
`EXCLUDE_DISK_BY_NAME`: Exclude disks by name.  
`ARRAY_FANS`: Define fan control locations.  


## Execution
Run the script, and it will dynamically adjust the fan speed based on disk temperatures.

```
./fan_control_script.sh
```
The script provides informative messages about the current state and the action taken.

For any unexpected conditions, it sets the fan speed to the maximum.

## Notifications
If a disk exceeds the `MAX_TEMP` threshold, an alert is sent through Unraid's notification system.


### Feel free to contribute, report issues, or suggest improvements! If you find this repository useful, don't forget to star it :)