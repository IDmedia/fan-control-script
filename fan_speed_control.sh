#!/bin/bash

# This script will automatically adjust the fans speed
# based on your hard drives temperature. You may select
# which disks to include and exclude and play around with
# different temperature settings.

# Prerequisites:
# 1. Enable manual fan speed control in Unraid
#    This can be done by editing "/boot/syslinux/syslinux.cfg"
#    Right beneath "label Unraid OS" you will have to change:
#    "append initrd=/bzroot" to "append initrd=/bzroot acpi_enforce_resources=lax"
# 2. Set the PWM headers you want to control to 100%/255 and mode to PWM in your BIOS

# Tips:
# In order to see what fan headers Unraid sees use "sensors -uA"
# Another useful tool is "pwmconfig". Makes it easier to find the correct fan header
# You may test your pwm pins from the terminal. Here is a list of attributes:
# pwm[1-5] - this file stores PWM duty cycle or DC value (fan speed) in range:
#     0 (lowest speed) to 255 (full)
# pwm[1-5]_enable - this file controls mode of fan/temperature control:
#   * 0 Fan control disabled (fans set to maximum speed)
#   * 1 Manual mode, write to pwm[0-5] any value 0-255
#   * 2 "Thermal Cruise" mode
#   * 3 "Fan Speed Cruise" mode
#   * 4 "Smart Fan III" mode (NCT6775F only)
#   * 5 "Smart Fan IV" mode
# pwm[1-5]_mode - controls if output is PWM or DC level
#   * 0 DC output
#   * 1 PWM output

# Create a fan curve graph
# Requires gnuplot (use on another Linux machine)
# Run with: ./fan_speed_control.sh --generate-graph-data

# Idle PWM value
# Used when all disks are spun down
# and fan speed will never be set to a lower value
IDLE_PWM=180

# Low/High PWM values
# Used for calculating new PWM values when
# disk temp is between LOW_TEMP and HIGH_TEMP temperature
LOW_PWM=170
HIGH_PWM=225

# Max PWM
# Used for setting the fan to max speed while parity
# is running or if the disk temperature is too hot
# This settings should in most cases NOT BE CHANGED!
MAX_PWM=255

# Low/High temperature
# Define the disks temperature range for when
# the fans speed should be automatically adjusted
LOW_TEMP=35
HIGH_TEMP=45

# Max temperature
# If the hottest disk reaches this temperature
# a notification will be sent through Unraid
MAX_TEMP=50

# Disks to monitor
# Select disks to include by type and
# exclude by name (found in disk.ini)
INCLUDE_DISK_TYPE_PARITY=1
INCLUDE_DISK_TYPE_DATA=1
INCLUDE_DISK_TYPE_CACHE=1
INCLUDE_DISK_TYPE_FLASH=0
EXCLUDE_DISK_BY_NAME=(
    "cache_system"
    "cache_system2"
)

# Array fans
# Define one or more fans that should be controlled by this script
ARRAY_FANS=(
	"/sys/class/hwmon/hwmon4/pwm1"
	"/sys/class/hwmon/hwmon4/pwm4"
)

############################################################

generate_graph_data=false

# Function to round a number to the nearest lower ten
round_down_to_nearest_ten() {
    echo $(( $1 - ($1 % 10) ))
}

# Function to round a number to the nearest higher ten
round_up_to_nearest_ten() {
    local num=$1
    echo $(( ((num + 9) / 10) * 10 ))
}

# Parse command-line arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --generate-graph-data) generate_graph_data=true ;;
        --output-file) graph_image_file="$2"; shift ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

if $generate_graph_data; then
    rounded_low_temp=$(round_down_to_nearest_ten $LOW_TEMP)
    rounded_max_temp=$(round_up_to_nearest_ten $MAX_TEMP)
    data_file=$(mktemp)

    min_pwm=$MAX_PWM
    max_pwm=0

    # Generate data points for the graph
    for temp in $(seq $rounded_low_temp $rounded_max_temp); do
        # Calculate fan speed based on temperature
        if (( temp <= LOW_TEMP )); then
            fan_pwm=$IDLE_PWM
        elif (( temp > LOW_TEMP && temp <= HIGH_TEMP )); then
            pwm_steps=$((HIGH_TEMP - LOW_TEMP - 1))
            pwm_increment=$(( (HIGH_PWM - LOW_PWM) / pwm_steps ))
            fan_pwm=$(( ((temp - LOW_TEMP - 1) * pwm_increment) + LOW_PWM ))
        elif (( temp > HIGH_TEMP && temp <= MAX_TEMP )); then
            fan_pwm=$MAX_PWM
        else
            fan_pwm=$MAX_PWM
        fi
        echo "$temp $fan_pwm" >> $data_file
        (( fan_pwm < min_pwm )) && min_pwm=$fan_pwm
        (( fan_pwm > max_pwm )) && max_pwm=$fan_pwm
    done

    # Create gnuplot script
	graph_image_file="fan_speed_control_graph.jpg"
    gnuplot_script=$(mktemp)
    cat << EOF > $gnuplot_script
set terminal jpeg size 1200,800 enhanced
set output "$graph_image_file"
set xlabel "Temperature (°C)"
set ylabel "Fan PWM"
set title "Fan PWM vs Temperature"
set grid
set key left top
set xrange [$rounded_low_temp:$rounded_max_temp]
set yrange [$min_pwm:$max_pwm]
set xtics 1
set ytics 10
plot '$data_file' using 1:2 with linespoints title "Fan Speed"
EOF

    # Run gnuplot with the created script
    gnuplot $gnuplot_script

    # Clean up
    rm $data_file $gnuplot_script
    echo "Graph image generated in $graph_image_file"
    exit 0
fi

# Make a list of disk types the user wants to monitor
declare -A include_disk_types
include_disk_types[Parity]=$INCLUDE_DISK_TYPE_PARITY
include_disk_types[Data]=$INCLUDE_DISK_TYPE_DATA
include_disk_types[Cache]=$INCLUDE_DISK_TYPE_CACHE
include_disk_types[Flash]=$INCLUDE_DISK_TYPE_FLASH

# Make a list of all the existing disks
declare -a disk_list_all
while IFS='= ' read var val
do
    if [[ $var == \[*] ]]
    then
        disk_name=${var:2:-2}
        disk_list_all+=($disk_name)
        eval declare -A ${disk_name}_data
    elif [[ $val ]]
    then
        eval ${disk_name}_data[$var]=$val
    fi
done < /var/local/emhttp/disks.ini

# Filter disk list based on criteria
declare -a disk_list
for disk in "${disk_list_all[@]}"
do
    disk_name=${disk}_data[name]
    disk_type=${disk}_data[type]
    disk_id=${disk}_data[id]
    disk_type_filter=${include_disk_types[${!disk_type}]}

    if [[ ! -z "${!disk_id}" ]] && \
       [[ "${disk_type_filter}" -ne 0 ]] && \
       [[ ! " ${EXCLUDE_DISK_BY_NAME[*]} " =~ " ${disk} " ]]
    then
        disk_list+=($disk)
    fi
done

# Check temperature
declare -A disk_state
declare -A disk_temp
disk_max_temp_value=0
disk_max_temp_name=null
disk_active_num=0

for disk in "${disk_list[@]}"
do
    # Check disk state
    eval state_value=${disk}_data[spundown]
    if (( ${state_value} == 1 ))
    then
        state=spundown
        disk_state[${disk}]=spundown
    else
        state=spunup
        disk_state[${disk}]=spunup
        disk_active_num=$((disk_active_num+1))
    fi

    # Check disk temperature
    temp=${disk}_data[temp]
    if [[ "$state" == "spunup" ]]
    then
        if [[ "${!temp}" =~ ^[0-9]+$ ]]
        then
            disk_temp[${disk}]=${!temp}
            if (( "${!temp}" > "$disk_max_temp_value" ))
            then
                disk_max_temp_value=${!temp}
                disk_max_temp_name=$disk
            fi
        else
            disk_temp[$disk]=unknown
        fi
    else
        disk_temp[$disk]=na
    fi
done


# Check if parity is running
disk_parity=$(awk -F'=' '$1=="mdResync" {gsub(/"/, "", $2); print $2}' /var/local/emhttp/var.ini)

# Linear PWM Logic
pwm_steps=$((HIGH_TEMP - LOW_TEMP - 1))
pwm_increment=$(( (HIGH_PWM - LOW_PWM) / pwm_steps))

# Print heighest disk temp if at least one is active
if [[ $disk_active_num -gt 0 ]]; then
    echo "Hottest disk is $disk_max_temp_name at $disk_max_temp_value°C"
fi

# Calculate new fan speed
# Handle cases where no disks are found
if [[ ${#disk_list[@]} -gt 0 && ${#disk_list[@]} -ne ${#disk_temp[@]} ]]
then
    fan_msg="No disks included or unable to read all disks"
    fan_pwm=$MAX_PWM

# Parity is running
elif [[ "$disk_parity" -gt 0 ]]
then
    fan_msg="Parity-Check is running"
    fan_pwm=$MAX_PWM

# All disk are spun down
elif [[ $disk_active_num -eq 0 ]]
then
    fan_msg="All disks are in standby mode"
	fan_pwm=$IDLE_PWM

# Hottest disk is below the LOW_TEMP threshold
elif (( $disk_max_temp_value <= $LOW_TEMP ))
then
	fan_msg="Temperature of $disk_max_temp_value°C is below LOW_TEMP ($LOW_TEMP°C)"
	fan_pwm=$IDLE_PWM

# Hottest disk is between LOW_TEMP and HIGH_TEMP
elif (( $disk_max_temp_value > $LOW_TEMP && $disk_max_temp_value <= $HIGH_TEMP ))
then
    fan_msg="Temperature of $disk_max_temp_value°C is between LOW_TEMP ($LOW_TEMP°C) and HIGH_TEMP ($HIGH_TEMP°C)"
	fan_pwm=$(( ((disk_max_temp_value - LOW_TEMP - 1) * pwm_increment) + LOW_PWM ))

# Hottest disk is between HIGH_TEMP and MAX_TEMP
elif (( $disk_max_temp_value > $HIGH_TEMP && $disk_max_temp_value <= $MAX_TEMP ))
then
    fan_msg="Temperature of $disk_max_temp_value°C is between HIGH_TEMP ($HIGH_TEMP°C) and MAX_TEMP ($MAX_TEMP°C)"
	fan_pwm=$MAX_PWM

# Hottest disk exceeds MAX_TEMP
elif (( $disk_max_temp_value > $MAX_TEMP ))
then
    alert_msg="$disk_max_temp_name exceeds ($MAX_TEMP°C)"
    fan_msg=$alert_msg
    fan_pwm=$MAX_PWM
    
    # Send an alert
    /usr/local/emhttp/webGui/scripts/notify \
        -i alert \
        -s "Disk (${disk_max_temp_name}) overheated" \
        -d "$alert_msg"

# Handle any unexpected condition
else
    fan_msg="An unexpected condition occurred"
    fan_pwm=$MAX_PWM
fi

# Apply fan speed
for fan in "${ARRAY_FANS[@]}"
do
    # Set fan mode to 1 if necessary
    pwm_mode=$(cat "${fan}_enable")
    if [[ $pwm_mode -ne 1 ]]; then
        echo 1 > "${fan}_enable"
    fi
    
    # Set fan speed
    echo $fan_pwm > $fan
done

pwm_percent=$(( (fan_pwm * 100) / 255 ))
echo "$fan_msg, setting fans to $fan_pwm PWM ($pwm_percent%)"
