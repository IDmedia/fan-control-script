#!/bin/bash

# Automatically adjusts fan speed based on hard drive temperatures

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

# Generate a fan curve graph (requires gnuplot)
# Run on another Linux machine with: ./fan_speed_control.sh --generate-graph-data

# Maximum PWM value for fan speed
# Applied when parity is running or disk temperature is too high
# WARNING: Altering this value is generally not recommended
MAX_PWM=255

# Minimum PWM value for fan speed
MIN_PWM=170

# Disk temperature range for dynamic fan speed adjustment
LOW_TEMP=35
HIGH_TEMP=48

# Maximum allowable disk temperature
# A notification will be sent through UnRAID if this is exceeded
ALERT_TEMP=50

# Disks to monitor
# Include disks by type and exclude by name (specified in disk.ini)
INCLUDE_DISK_TYPE_PARITY=1
INCLUDE_DISK_TYPE_DATA=1
INCLUDE_DISK_TYPE_CACHE=1
INCLUDE_DISK_TYPE_FLASH=0
EXCLUDE_DISK_BY_NAME=(
    "cache_system"
    "cache_system2"
)

# Array fans to be controlled by this script
ARRAY_FANS=(
    "/sys/class/hwmon/hwmon4/pwm1"
    "/sys/class/hwmon/hwmon4/pwm4"
)

############################################################

# Parse command-line arguments
generate_graph_data=false
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --generate-graph-data)
            generate_graph_data=true
            ;;
        --output-file)
            if [[ -n "$2" ]]; then
                graph_image_file="$2"
                shift
            else
                echo "Error: --output-file requires a non-empty argument."
                exit 1
            fi
            ;;
    esac
    shift
done


# Function to check if a file exists
check_file_exists() {
    local file_path=$1
    if [[ ! -f $file_path ]]; then
        echo "Error: $file_path does not exist."
        exit 1
    fi
}

# Function to calculate fan PWM based on temperature
calculate_fan_pwm() {
    local temp=$1
    local fan_pwm

    if (( temp <= LOW_TEMP )); then
        fan_pwm=$MIN_PWM
    elif (( temp > LOW_TEMP && temp <= HIGH_TEMP )); then
        pwm_steps=$((HIGH_TEMP - LOW_TEMP))
        pwm_increment=$(( (MAX_PWM - MIN_PWM) / pwm_steps ))
        fan_pwm=$(( ((temp - LOW_TEMP) * pwm_increment) + MIN_PWM ))
    else
        fan_pwm=$MAX_PWM
    fi

    echo $fan_pwm
}

if $generate_graph_data; then
    padded_low_temp=$((LOW_TEMP - 5))
    padded_high_temp=$((HIGH_TEMP + 5))
    data_file=$(mktemp)

    min_pwm=$MAX_PWM
    max_pwm=0

    # Generate data points for the graph
    for temp in $(seq $padded_low_temp $padded_high_temp); do
        fan_pwm=$(calculate_fan_pwm $temp)
        echo "$temp $fan_pwm" >> $data_file
        (( fan_pwm < min_pwm )) && min_pwm=$fan_pwm
        (( fan_pwm > max_pwm )) && max_pwm=$fan_pwm
    done

    # Check if gnuplot is available
    if ! command -v gnuplot &> /dev/null; then
        echo "gnuplot is not installed. Please install gnuplot and try again."
        exit 1
    fi

    # Create gnuplot script
    graph_image_file="fan_speed_graph.png"
    gnuplot_script=$(mktemp)
    cat << EOF > $gnuplot_script
set terminal jpeg size 1200,800 enhanced
set output "$graph_image_file"
set xlabel "Temperature (°C)"
set ylabel "Fan PWM"
set title "Fan PWM vs Temperature"
set grid
set key left top
set xrange [$padded_low_temp:$padded_high_temp]
set yrange [$min_pwm:260]
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

# Check for the existence of required files
check_file_exists "/var/local/emhttp/disks.ini"
check_file_exists "/var/local/emhttp/var.ini"

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
pwm_increment=$(( (MAX_PWM - MIN_PWM) / pwm_steps))

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
    fan_pwm=$MIN_PWM

# Hottest disk is below the LOW_TEMP threshold
elif (( $disk_max_temp_value <= $LOW_TEMP ))
then
    fan_msg="Temperature of $disk_max_temp_value°C is below LOW_TEMP ($LOW_TEMP°C)"
    fan_pwm=$MIN_PWM

# Hottest disk is between LOW_TEMP and HIGH_TEMP
elif (( $disk_max_temp_value > $LOW_TEMP && $disk_max_temp_value <= $HIGH_TEMP ))
then
    fan_msg="Temperature of $disk_max_temp_value°C is between LOW_TEMP ($LOW_TEMP°C) and HIGH_TEMP ($HIGH_TEMP°C)"
    fan_pwm=$(calculate_fan_pwm $disk_max_temp_value)

# Hottest disk is between HIGH_TEMP and HIGH_TEMP
elif (( $disk_max_temp_value > $HIGH_TEMP && $disk_max_temp_value <= $HIGH_TEMP ))
then
    fan_msg="Temperature of $disk_max_temp_value°C is between HIGH_TEMP ($HIGH_TEMP°C) and HIGH_TEMP ($HIGH_TEMP°C)"
    fan_pwm=$MAX_PWM

# Hottest disk is below the LOW_TEMP threshold
elif (( $disk_max_temp_value > $HIGH_TEMP ))
then
    fan_msg="Temperature of $disk_max_temp_value°C is above HIGH_TEMP ($HIGH_TEMP°C)"
    fan_pwm=$MAX_PWM

# Hottest disk exceeds ALERT_TEMP
elif (( $disk_max_temp_value > $ALERT_TEMP ))
then
    alert_msg="$disk_max_temp_name exceeds ($ALERT_TEMP°C)"
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

pwm_percent=$(( (fan_pwm * 100) / $MAX_PWM ))
echo "$fan_msg, setting fans to $fan_pwm PWM ($pwm_percent%)"
