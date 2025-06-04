#!/bin/bash
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # 
# #   Script for watching a dataset and auto updating regular folders converting them to datasets                                         # #
# #   (needs Unraid 6.12 or above)                                                                                                        # # 
# #   by - SpaceInvaderOne                                                                                                                # # 
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # 
#set -x

## Please consider this script in beta at the moment.
## new functions
## Auto stop only docker containers whose appdata is not zfs based.
## Auto stop only vms whose vdisk folder is not a dataset
## Add extra datasets to auto update to source_datasets_array
## Normalises German umlauts into ascii
## Various safety and other checks

# ---------------------------------------
# Main Variables
# ---------------------------------------

# real run or dry run
dry_run="no"  # Set to "yes" for a dry run. Change to "no" to run for real

# ---------------------------------------
# Notification Settings
# ---------------------------------------

# Enable/disable notifications
enable_notifications="yes"  # Set to "yes" to enable Unraid notifications, "no" to disable

# Configure which events to notify about (set to "yes" to enable each type)
notify_script_start="yes"           # Script started
notify_script_completion="yes"      # Script completed successfully  
notify_conversion_summary="yes"     # Summary of folders converted
notify_errors="yes"                 # Errors and failures
notify_warnings="yes"               # Warnings (validation issues, insufficient space, etc.)
notify_resume_operations="yes"      # When resuming interrupted conversions
notify_container_vm_stops="yes"     # When containers/VMs are stopped/started
notify_space_issues="yes"           # When skipping due to insufficient space

# ---------------------------------------
# Paths
# ---------------------------------------

# Process Docker Containers
should_process_containers="no"  # set to "yes" to process and convert appdata. set paths below
source_pool_where_appdata_is="sg1_storage"  #source pool
source_dataset_where_appdata_is="appdata"   #source appdata dataset

# Process Virtual Machines
should_process_vms="no"  # set to "yes" to process and convert vm vdisk folders. set paths below
source_pool_where_vm_domains_are="darkmatter_disks"  # source pool
source_dataset_where_vm_domains_are="domains"        # source domains dataset
vm_forceshutdown_wait="90"                           # how long to wait for vm to shutdown without force stopping it

# Additional User-Defined Datasets
# Add more paths as needed in the format pool/dataset in quotes, for example: "tank/mydata"
source_datasets_array=(
  # ... user-defined paths here ...
)

cleanup="yes"
replace_spaces="no"

# ---------------------------------------
# Advanced Variables - No need to modify
# ---------------------------------------

# Check if container processing is set to "yes". If so, add location to array and create bind mount compare variable.
if [[ "$should_process_containers" =~ ^[Yy]es$ ]]; then
    source_datasets_array+=("${source_pool_where_appdata_is}/${source_dataset_where_appdata_is}")
    source_path_appdata="$source_pool_where_appdata_is/$source_dataset_where_appdata_is"
fi

# Check if VM processing is set to "yes". If so, add location to array and create vdisk compare variable.
if [[ "$should_process_vms" =~ ^[Yy]es$ ]]; then
    source_datasets_array+=("${source_pool_where_vm_domains_are}/${source_dataset_where_vm_domains_are}")
    source_path_vms="$source_pool_where_vm_domains_are/$source_dataset_where_vm_domains_are"
fi

mount_point="/mnt"
stopped_containers=()
stopped_vms=()
converted_folders=()
buffer_zone=11

#--------------------------------
#     FUNCTIONS START HERE      #
#--------------------------------

#----------------------------------------------------------------------------------    
# this function sends Unraid notifications
#
send_notification() {
  local event="$1"
  local subject="$2" 
  local description="$3"
  local importance="$4"  # normal, warning, or alert
  local notification_type="$5"  # Which notification setting to check
  
  # Check if notifications are enabled globally
  if [ "$enable_notifications" != "yes" ]; then
    return 0
  fi
  
  # Check if this specific notification type is enabled
  local notify_var="notify_${notification_type}"
  local notify_enabled="${!notify_var}"
  if [ "$notify_enabled" != "yes" ]; then
    return 0
  fi
  
  # Don't send notifications in dry run mode (except for dry run start notification)
  if [ "$dry_run" = "yes" ] && [ "$notification_type" != "script_start" ]; then
    echo "Dry Run: Would send notification - $event: $subject"
    return 0
  fi
  
  # Send the notification with proper line break formatting
  if command -v /usr/local/emhttp/webGui/scripts/notify >/dev/null 2>&1; then
    # Use printf to properly format the description with line breaks
    local formatted_description=$(printf "%b" "$description")
    /usr/local/emhttp/webGui/scripts/notify -e "$event" -s "$subject" -d "$formatted_description" -i "$importance"
    echo "Notification sent: $subject"
  else
    echo "Unraid notify command not found. Notification skipped: $subject"
  fi
}

#-------------------------------------------------------------------------------------------------
# this function finds the real location of union folder  ie unraid /mnt/user
#
find_real_location() {
  local path="$1"

  if [[ ! -e $path ]]; then
    echo "Path not found."
    return 1
  fi

  for disk_path in /mnt/*/; do
    if [[ "$disk_path" != "/mnt/user/" && -e "${disk_path%/}${path#/mnt/user}" ]]; then
      echo "${disk_path%/}${path#/mnt/user}"
      return 0
    fi
  done

  echo "Real location not found."
  return 2
}

#---------------------------
# this function checks if location is an actively mounted ZFS dataset or not
#
is_zfs_dataset() {
  local location="$1"
  
  if zfs list -H -o mounted,mountpoint | grep -q "^yes"$'\t'"$location$"; then
    return 0
  else
    return 1
  fi
}

#-----------------------------------------------------------------------------------------------------------------------------------  #
# this function checks the running containers and sees if bind mounts are folders or datasets and shuts down containers if needed #
stop_docker_containers() {
  if [ "$should_process_containers" = "yes" ]; then
    echo "Checking Docker containers..."
    
    for container in $(docker ps -q); do
      local container_name=$(docker container inspect --format '{{.Name}}' "$container" | cut -c 2-)
      local bindmounts=$(docker inspect --format '{{ range .Mounts }}{{ if eq .Type "bind" }}{{ .Source }}{{printf "\n"}}{{ end }}{{ end }}' $container) 
      
      if [ -z "$bindmounts" ]; then
        echo "Container ${container_name} has no bind mounts so nothing to convert. No need to stop the container."
        continue
      fi
      
      local stop_container=false

      while IFS= read -r bindmount; do
        if [[ "$bindmount" == /mnt/user/* ]]; then
            bindmount=$(find_real_location "$bindmount")
            if [[ $? -ne 0 ]]; then
                echo "Error finding real location for $bindmount in container $container_name."
                continue
            fi
        fi

        # check if bind mount matches source_path_appdata, if not, skip it
        if [[ "$bindmount" != "/mnt/$source_path_appdata"* ]]; then
            continue
        fi

        local immediate_child=$(echo "$bindmount" | sed -n "s|^/mnt/$source_path_appdata/||p" | cut -d "/" -f 1)
        local combined_path="/mnt/$source_path_appdata/$immediate_child"

        is_zfs_dataset "$combined_path"
        if [[ $? -eq 1 ]]; then
          echo "The appdata for container ${container_name} is not a ZFS dataset (it's a folder). Container will be stopped so it can be converted to a dataset."
          stop_container=true
          break
        fi
      done <<< "$bindmounts"  #  send  bindmounts into the loop

      if [ "$stop_container" = true ]; then
        docker stop "$container"
        stopped_containers+=("$container_name")
      else
        echo "Container ${container_name} is not required to be stopped as it is already a separate dataset."
      fi
    done

    if [ "${#stopped_containers[@]}" -gt 0 ]; then
      echo "The container/containers ${stopped_containers[*]} has/have been stopped during conversion and will be restarted afterwards."
      send_notification "ZFS Dataset Converter" "Docker Containers Stopped" "The following containers were stopped for dataset conversion: ${stopped_containers[*]}

They will be restarted after conversion completes." "warning" "container_vm_stops"
    fi
  fi
}
#----------------------------------------------------------------------------------    
# this function restarts any containers that had to be stopped
#
start_docker_containers() {
  if [ "$should_process_containers" = "yes" ]; then
    if [ "${#stopped_containers[@]}" -gt 0 ]; then
      send_notification "ZFS Dataset Converter" "Restarting Docker Containers" "Restarting containers that were stopped for conversion: ${stopped_containers[*]}" "normal" "container_vm_stops"
    fi
    
    for container_name in "${stopped_containers[@]}"; do
      echo "Restarting Docker container $container_name..."
      if [ "$dry_run" != "yes" ]; then
        docker start "$container_name"
      else
        echo "Dry Run: Docker container $container_name would be restarted"
      fi
    done
  fi
}


# ----------------------------------------------------------------------------------    
#this function gets  dataset path from the full vdisk path
#
get_dataset_path() {
    local fullpath="$1"
    # Extract dataset path
    echo "$fullpath" | rev | cut -d'/' -f2- | rev
}

#------------------------------------------    
# this function getsvdisk info from a vm
#
get_vm_disk() {
    local vm_name="$1"
    # Redirecting debug output to stderr
    echo "Fetching disk for VM: $vm_name" >&2

    # Get target (like hdc, hda, etc.)
    local vm_target=$(virsh domblklist "$vm_name" --details | grep disk | awk '{print $3}')

    # Check if target was found
    if [ -n "$vm_target" ]; then
        # Get the disk for the given target
        local vm_disk=$(virsh domblklist "$vm_name" | grep "$vm_target" | awk '{$1=""; print $0}' | sed 's/^[ \t]*//;s/[ \t]*$//')
        # Redirecting debug output to stderr
        echo "Found disk for $vm_name at target $vm_target: $vm_disk" >&2
        echo "$vm_disk"
    else
        # Redirecting error output to stderr
        echo "Disk not found for VM: $vm_name" >&2
        return 1
    fi
}

#-----------------------------------------------------------------------------------------------------------------------------------  
# this function checks the vdisks any running vm. If visks is not inside a dataset it will stop the vm for processing the conversion
stop_virtual_machines() {
  if [ "$should_process_vms" = "yes" ]; then
    echo "Checking running VMs..."
    
    while IFS= read -r vm; do
      if [ -z "$vm" ]; then
        # Skip if VM name is empty
        continue
      fi

      local vm_disk=$(get_vm_disk "$vm")

      # If the disk is not set, skip this vm
      if [ -z "$vm_disk" ]; then
        echo "No disk found for VM $vm. Skipping..."
        continue
      fi
      
      # Check if VM disk is in a folder and matches source_path_vms
      if [[ "$vm_disk" == /mnt/user/* ]]; then
          vm_disk=$(find_real_location "$vm_disk")
          if [[ $? -ne 0 ]]; then
              echo "Error finding real location for $vm_disk in VM $vm."
              continue
          fi
      fi

      # Check if vm_disk matches source_path_vms, if not, skip it
      if [[ "$vm_disk" != "/mnt/$source_path_vms"* ]]; then
          continue
      fi

      local dataset_path=$(get_dataset_path "$vm_disk")
      local immediate_child=$(echo "$dataset_path" | sed -n "s|^/mnt/$source_path_vms/||p" | cut -d "/" -f 1)
      local combined_path="/mnt/$source_path_vms/$immediate_child"

      is_zfs_dataset "$combined_path"
      if [[ $? -eq 1 ]]; then
        echo "The vdisk for VM ${vm} is not a ZFS dataset (it's a folder). VM will be stopped so it can be converted to a dataset."
        
        if [ "$dry_run" != "yes" ]; then
            virsh shutdown "$vm"  
            
      #  waiting loop for the VM to shutdown
      local start_time=$(date +%s)
      while virsh dominfo "$vm" | grep -q 'running'; do
    sleep 5
    local current_time=$(date +%s)
    if (( current_time - start_time >= $vm_forceshutdown_wait )); then
        echo "VM $vm has not shut down after $vm_forceshutdown_wait seconds. Forcing shutdown now."
        virsh destroy "$vm"
        break
    fi
done
        else
            echo "Dry Run: VM $vm would be stopped"
        fi
        stopped_vms+=("$vm")
      else
        echo "VM ${vm} is not required to be stopped as its vdisk is already in its own dataset."
      fi
    done < <(virsh list --name | grep -v '^$')  # filter empty lines

    if [ "${#stopped_vms[@]}" -gt 0 ]; then
      echo "The VM/VMs ${stopped_vms[*]} has/have been stopped during conversion and will be restarted afterwards."
      send_notification "ZFS Dataset Converter" "Virtual Machines Stopped" "The following VMs were stopped for dataset conversion: ${stopped_vms[*]}

They will be restarted after conversion completes." "warning" "container_vm_stops"
    fi
  fi
}

#----------------------------------------------------------------------------------    
# this function restarts any vms that had to be stopped
#
start_virtual_machines() {
  if [ "$should_process_vms" = "yes" ]; then
    if [ "${#stopped_vms[@]}" -gt 0 ]; then
      send_notification "ZFS Dataset Converter" "Restarting Virtual Machines" "Restarting VMs that were stopped for conversion: ${stopped_vms[*]}" "normal" "container_vm_stops"
    fi
    
    for vm in "${stopped_vms[@]}"; do
      echo "Restarting VM $vm..."
      if [ "$dry_run" != "yes" ]; then
        virsh start "$vm"  
      else
        echo "Dry Run: VM $vm would be restarted"
      fi
    done
  fi
}

#----------------------------------------------------------------------------------    
# this function performs intelligent validation of copy operations
#
perform_validation() {
    local source_dir="$1"
    local dest_dir="$2"
    local operation_name="$3"
    
    echo "Validating $operation_name..."
    
    source_file_count=$(find "$source_dir" -type f | wc -l)
    destination_file_count=$(find "$dest_dir" -type f | wc -l)
    source_total_size=$(du -sb "$source_dir" | cut -f1)
    destination_total_size=$(du -sb "$dest_dir" | cut -f1)
    
    echo "Source files: $source_file_count, Destination files: $destination_file_count"
    echo "Source total size: $source_total_size, Destination total size: $destination_total_size"
    
    # More intelligent validation:
    # 1. Destination should have at least as many files as source
    # 2. Destination should have at least as much data as source  
    # 3. Allow for reasonable differences (up to 5% more files/data in destination)
    
    file_diff=$((destination_file_count - source_file_count))
    size_diff=$((destination_total_size - source_total_size))
    
    # Calculate acceptable thresholds (5% more than source)
    max_extra_files=$((source_file_count / 20))  # 5% of source files
    max_extra_size=$((source_total_size / 20))   # 5% of source size
    
    # Check if destination has fewer files or significantly less data
    if [ "$destination_file_count" -lt "$source_file_count" ]; then
        echo "VALIDATION FAILED: Destination has fewer files than source"
        echo "Missing files: $((source_file_count - destination_file_count))"
        send_notification "ZFS Dataset Converter" "Validation Failed - Missing Files" "Copy validation failed for: $operation_name
Source files: $source_file_count
Destination files: $destination_file_count
Missing: $((source_file_count - destination_file_count)) files" "alert" "errors"
        return 1
    elif [ "$destination_total_size" -lt "$source_total_size" ]; then
        echo "VALIDATION FAILED: Destination has less data than source"
        echo "Missing data: $((source_total_size - destination_total_size)) bytes"
        send_notification "ZFS Dataset Converter" "Validation Failed - Missing Data" "Copy validation failed for: $operation_name
Source size: $(numfmt --to=iec $source_total_size)
Destination size: $(numfmt --to=iec $destination_total_size)
Missing: $(numfmt --to=iec $((source_total_size - destination_total_size)))" "alert" "errors"
        return 1
    elif [ "$file_diff" -gt "$max_extra_files" ]; then
        echo "VALIDATION WARNING: Destination has significantly more files than expected"
        echo "Extra files: $file_diff (threshold: $max_extra_files)"
        echo "This might be normal (hidden files, metadata, etc.) but please verify manually"
        send_notification "ZFS Dataset Converter" "Validation Warning - Extra Files" "Copy validation warning for: $operation_name
Destination has $file_diff extra files (threshold: $max_extra_files)
This might be normal but manual verification recommended." "warning" "warnings"
        return 2  # Warning, but not a failure
    elif [ "$size_diff" -gt "$max_extra_size" ]; then
        echo "VALIDATION WARNING: Destination has significantly more data than expected"
        echo "Extra data: $size_diff bytes (threshold: $max_extra_size bytes)"
        echo "This might be normal but please verify manually"
        send_notification "ZFS Dataset Converter" "Validation Warning - Extra Data" "Copy validation warning for: $operation_name
Destination has $(numfmt --to=iec $size_diff) extra data
This might be normal but manual verification recommended." "warning" "warnings"
        return 2  # Warning, but not a failure
    else
        echo "VALIDATION SUCCESSFUL: Copy completed successfully"
        echo "Extra files: $file_diff, Extra data: $size_diff bytes (within acceptable range)"
        return 0
    fi
}

#----------------------------------------------------------------------------------    
# this function validates if a dataset name is valid for ZFS
#
validate_dataset_name() {
  local name="$1"
  
  # Check if name contains invalid characters for ZFS using case statement approach
  if [[ "$name" == *"("* ]] || [[ "$name" == *")"* ]] || [[ "$name" == *"{"* ]] || \
     [[ "$name" == *"}"* ]] || [[ "$name" == *"["* ]] || [[ "$name" == *"]"* ]] || \
     [[ "$name" == *"<"* ]] || [[ "$name" == *">"* ]] || [[ "$name" == *"|"* ]] || \
     [[ "$name" == *"*"* ]] || [[ "$name" == *"?"* ]] || [[ "$name" == *"&"* ]] || \
     [[ "$name" == *","* ]] || [[ "$name" == *"'"* ]] || [[ "$name" == *" "* ]]; then
    echo "Dataset name contains invalid characters: $name"
    return 1
  fi
  
  # Check if name is empty
  if [ -z "$name" ]; then
    echo "Dataset name cannot be empty"
    return 1
  fi
  
  # Check if name is too long (ZFS limit is 256 characters for full path)
  if [ ${#name} -gt 200 ]; then
    echo "Dataset name too long: $name"
    return 1
  fi
  
  return 0
}

#----------------------------------------------------------------------------------    
# this function normalises umlauts and special characters for ZFS dataset names
#
normalize_name() {
  local original_name="$1"
  # Replace German umlauts with ASCII approximations and remove/replace invalid ZFS characters
  local normalized_name=$(echo "$original_name" | 
                          sed 's/ä/ae/g; s/ö/oe/g; s/ü/ue/g; 
                               s/Ä/Ae/g; s/Ö/Oe/g; s/Ü/Ue/g; 
                               s/ß/ss/g' |
                          sed 's/[()\[\]{}]//g; s/[&,'"'"']/_/g; s/[<>|*?]/_/g; s/[[:space:]]\+/_/g; s/__*/_/g; s/^_//; s/_$//')
  
  # Ensure the name is not empty and doesn't start with a number or special character
  if [ -z "$normalized_name" ]; then
    normalized_name="unnamed_folder"
  elif [[ "$normalized_name" =~ ^[0-9] ]]; then
    normalized_name="folder_${normalized_name}"
  fi
  
  echo "$normalized_name"
}

#----------------------------------------------------------------------------------    
# this function creates the new datasets and does the conversion
#
create_datasets() {
  local source_path="$1"
  
  # Enhanced resume logic - Check for interrupted conversions to resume
  echo "Checking for interrupted conversions to resume in ${source_path}..."

  local temp_dirs_found=false
  
  # First, handle any leftover _temp directories
  for tmp_dir in "${mount_point}/${source_path}"/*_temp; do
    # Skip if no temp directories found (glob doesn't match)
    [ -d "$tmp_dir" ] || continue
    
    # Skip if this is just the glob pattern unexpanded
    [[ "$tmp_dir" == "${mount_point}/${source_path}/*_temp" ]] && continue
    
    temp_dirs_found=true
    
    # Extract the base name (without _temp suffix)
    temp_base=$(basename "$tmp_dir" _temp)
    
    # Apply the same normalization logic as the main script
    temp_base_no_spaces=$(if [ "$replace_spaces" = "yes" ]; then echo "$temp_base" | tr ' ' '_'; else echo "$temp_base"; fi)
    normalized_temp_base=$(normalize_name "$temp_base_no_spaces")
    
    dataset_name="${source_path}/${normalized_temp_base}"
    dataset_mountpoint="${mount_point}/${source_path}/${normalized_temp_base}"
    
    echo "Found temp directory: $tmp_dir"
    echo "Original base name: $temp_base"
    echo "After space replacement: $temp_base_no_spaces"
    echo "After normalization: $normalized_temp_base"
    echo "Expected dataset: $dataset_name"
    
    # Validate the dataset name
    if ! validate_dataset_name "$normalized_temp_base"; then
      echo "Skipping temp directory ${tmp_dir} due to invalid dataset name: $normalized_temp_base"
      continue
    fi
    
    # Check if corresponding dataset exists
    if zfs list -H -o name 2>/dev/null | grep -q "^${dataset_name}$"; then
      echo "Dataset $dataset_name exists. Resuming copy from temp directory..."
      send_notification "ZFS Dataset Converter" "Resuming Interrupted Conversion" "Resuming conversion for: $temp_base
From: $tmp_dir
To: $dataset_name" "normal" "resume_operations"
      
      if [ "$dry_run" != "yes" ]; then
        # Resume the rsync operation
        rsync -a --progress "$tmp_dir/" "$dataset_mountpoint/"
        rsync_exit_status=$?
        
        if [ $rsync_exit_status -eq 0 ]; then
          echo "Resume successful for $normalized_temp_base"
          
          # Perform validation if cleanup is enabled
          if [ "$cleanup" = "yes" ]; then
            perform_validation "$tmp_dir" "$dataset_mountpoint" "resumed copy"
            validation_result=$?
            
            if [ $validation_result -eq 0 ]; then
              echo "Validation successful. Cleaning up temp directory."
              echo "This may take several minutes for large directories..."
              
              # Get initial size for progress feedback
              if command -v du >/dev/null 2>&1; then
                temp_size=$(du -sh "$tmp_dir" 2>/dev/null | cut -f1)
                echo "Deleting temp directory ($temp_size): $tmp_dir"
              fi
              
              # Use background process with periodic updates for large deletions
              if [ $(find "$tmp_dir" -type f | wc -l) -gt 10000 ]; then
                echo "Large directory detected. Starting background cleanup with progress updates..."
                (
                  rm -rf "$tmp_dir" 
                  echo "CLEANUP_COMPLETE:$tmp_dir" >> /tmp/zfs_converter_cleanup.log
                ) &
                cleanup_pid=$!
                
                # Monitor cleanup progress
                while kill -0 $cleanup_pid 2>/dev/null; do
                  if [ -d "$tmp_dir" ]; then
                    remaining=$(find "$tmp_dir" -type f 2>/dev/null | wc -l)
                    echo "Cleanup in progress... $remaining files remaining"
                  fi
                  sleep 10
                done
                wait $cleanup_pid
                echo "Background cleanup completed."
              else
                rm -rf "$tmp_dir"
              fi
              
              echo "Temp directory cleanup completed: $tmp_dir"
              converted_folders+=("${mount_point}/${source_path}/${temp_base}")
            elif [ $validation_result -eq 2 ]; then
              echo "Validation completed with warnings. Manual verification recommended."
              echo "Temp directory preserved at: $tmp_dir"
              echo "You can manually remove it after verification with: rm -rf '$tmp_dir'"
            else
              echo "Validation failed for resumed copy. Keeping temp directory."
              echo "Check: $tmp_dir vs $dataset_mountpoint"
            fi
          else
            echo "Cleanup disabled. Keeping temp directory: $tmp_dir"
          fi
        else
          echo "Resume failed for $tmp_dir. Rsync exit status: $rsync_exit_status"
          send_notification "ZFS Dataset Converter" "Resume Operation Failed" "Failed to resume conversion for: $temp_base
Temp directory: $tmp_dir
Rsync exit status: $rsync_exit_status" "alert" "errors"
        fi
      else
        echo "Dry Run: Would resume copy from $tmp_dir to $dataset_mountpoint"
      fi
      
    else
      echo "No corresponding dataset found for temp directory $tmp_dir"
      echo "Checking if we need to create the dataset..."
      
      # Check available space before attempting to create dataset
      temp_size=$(du -sb "$tmp_dir" | cut -f1)
      buffer_zone_size=$((temp_size * buffer_zone / 100))
      
      if (( $(zfs list -o avail -p -H "${source_path}") >= buffer_zone_size )); then
        echo "Sufficient space available. Creating dataset and resuming..."
        
        if [ "$dry_run" != "yes" ]; then
          if zfs create "$dataset_name"; then
            echo "Dataset created successfully. Copying data..."
            rsync -a "$tmp_dir/" "$dataset_mountpoint/"
            rsync_exit_status=$?
            echo "Rsync completed with exit status: $rsync_exit_status"
            
            if [ $rsync_exit_status -eq 0 ] && [ "$cleanup" = "yes" ]; then
              perform_validation "${mount_point}/${source_path}/${normalized_temp_base}_temp" "${mount_point}/${source_path}/${normalized_temp_base}" "copy operation"
              validation_result=$?
              
              if [ $validation_result -eq 0 ]; then
                echo "Validation successful. Cleaning up temp directory."
                echo "This may take several minutes for large directories..."
                
                if command -v du >/dev/null 2>&1; then
                  temp_size=$(du -sh "${mount_point}/${source_path}/${normalized_temp_base}_temp" 2>/dev/null | cut -f1)
                  echo "Deleting temp directory ($temp_size): ${mount_point}/${source_path}/${normalized_temp_base}_temp"
                fi
                
                temp_cleanup_path="${mount_point}/${source_path}/${normalized_temp_base}_temp"
                if [ $(find "$temp_cleanup_path" -type f | wc -l) -gt 10000 ]; then
                  echo "Large directory detected. Starting background cleanup..."
                  (
                    rm -rf "$temp_cleanup_path"
                    echo "CLEANUP_COMPLETE:$temp_cleanup_path" >> /tmp/zfs_converter_cleanup.log
                  ) &
                  cleanup_pid=$!
                  
                  while kill -0 $cleanup_pid 2>/dev/null; do
                    if [ -d "$temp_cleanup_path" ]; then
                      remaining=$(find "$temp_cleanup_path" -type f 2>/dev/null | wc -l)
                      echo "Cleanup in progress... $remaining files remaining"
                    fi
                    sleep 10
                  done
                  wait $cleanup_pid
                  echo "Background cleanup completed."
                else
                  rm -rf "$temp_cleanup_path"
                fi
                
                converted_folders+=("${mount_point}/${source_path}/${temp_base}")
              elif [ $validation_result -eq 2 ]; then
                echo "Validation completed with warnings. Manual verification recommended."
                echo "Temp directory preserved at: ${mount_point}/${source_path}/${normalized_temp_base}_temp"
                echo "You can manually remove it after verification."
              else
                echo "Validation failed. Keeping temp directory for investigation."
                echo "Check: ${mount_point}/${source_path}/${normalized_temp_base}_temp vs ${mount_point}/${source_path}/${normalized_temp_base}"
              fi
            fi
          else
            echo "Failed to create dataset $dataset_name"
            send_notification "ZFS Dataset Converter" "Dataset Creation Failed" "Failed to create dataset: $dataset_name
For temp directory: $tmp_dir" "alert" "errors"
          fi
        else
          echo "Dry Run: Would create dataset $dataset_name and copy from $tmp_dir"
        fi
      else
        echo "Insufficient space to resume conversion of $tmp_dir"
        echo "Required: $(numfmt --to=iec $buffer_zone_size), Available: $(numfmt --to=iec $(zfs list -o avail -p -H "${source_path}"))"
        send_notification "ZFS Dataset Converter" "Insufficient Space for Resume" "Cannot resume conversion due to insufficient space:
Folder: $temp_base
Required: $(numfmt --to=iec $buffer_zone_size)
Available: $(numfmt --to=iec $(zfs list -o avail -p -H "${source_path}"))" "warning" "space_issues"
      fi
    fi
    
    echo "---"
  done
  
  if [ "$temp_dirs_found" = false ]; then
    echo "No temp directories found in ${source_path}. No interrupted conversions to resume."
  fi
  
  echo "Completed temp directory processing for ${source_path}"
  echo "Resume check completed. Proceeding with normal processing..."
  echo "---"
  
  # Original main processing loop
  for entry in "${mount_point}/${source_path}"/*; do
    base_entry=$(basename "$entry")
    if [[ "$base_entry" != *_temp ]]; then
      base_entry_no_spaces=$(if [ "$replace_spaces" = "yes" ]; then echo "$base_entry" | tr ' ' '_'; else echo "$base_entry"; fi)
      normalized_base_entry=$(normalize_name "$base_entry_no_spaces")
      
      if zfs list -o name | grep -qE "^${source_path}/${normalized_base_entry}$"; then
        echo "Skipping dataset ${entry}..."
      elif [ -d "$entry" ]; then
        echo "Processing folder ${entry}..."
        echo "Original name: $base_entry"
        echo "After space replacement: $base_entry_no_spaces"  
        echo "After normalization: $normalized_base_entry"
        folder_size=$(du -sb "$entry" | cut -f1)  # This is in bytes
        folder_size_hr=$(du -sh "$entry" | cut -f1)  # This is in human readable
        echo "Folder size: $folder_size_hr"
        buffer_zone_size=$((folder_size * buffer_zone / 100))
        
        if zfs list -o name | grep -qE "^${source_path}" && (( $(zfs list -o avail -p -H "${source_path}") >= buffer_zone_size )); then
          # Validate the dataset name before attempting to create it
          if ! validate_dataset_name "$normalized_base_entry"; then
            echo "Skipping folder ${entry} due to invalid dataset name: $normalized_base_entry"
            send_notification "ZFS Dataset Converter" "Invalid Dataset Name" "Skipping folder due to invalid dataset name:
Folder: $base_entry
Normalized: $normalized_base_entry
Path: $entry" "warning" "warnings"
            continue
          fi
          
          echo "Creating and populating new dataset ${source_path}/${normalized_base_entry}..."
          if [ "$dry_run" != "yes" ]; then
            mv "$entry" "${mount_point}/${source_path}/${normalized_base_entry}_temp"
            if zfs create "${source_path}/${normalized_base_entry}"; then
              rsync -a "${mount_point}/${source_path}/${normalized_base_entry}_temp/" "${mount_point}/${source_path}/${normalized_base_entry}/"
              rsync_exit_status=$?
              if [ "$cleanup" = "yes" ] && [ $rsync_exit_status -eq 0 ]; then
                perform_validation "${mount_point}/${source_path}/${normalized_base_entry}_temp" "${mount_point}/${source_path}/${normalized_base_entry}" "copy operation"
                validation_result=$?
                
                if [ $validation_result -eq 0 ]; then
                  echo "Validation successful, cleanup can proceed."
                  echo "This may take several minutes for large directories..."
                  
                  temp_path="${mount_point}/${source_path}/${normalized_base_entry}_temp"
                  if command -v du >/dev/null 2>&1; then
                    temp_size=$(du -sh "$temp_path" 2>/dev/null | cut -f1)
                    echo "Deleting temp directory ($temp_size): $temp_path"
                  fi
                  
                  # Use background process for large deletions
                  if [ $(find "$temp_path" -type f | wc -l) -gt 10000 ]; then
                    echo "Large directory detected. Starting background cleanup..."
                    (
                      rm -r "$temp_path"
                      echo "CLEANUP_COMPLETE:$temp_path" >> /tmp/zfs_converter_cleanup.log
                    ) &
                    cleanup_pid=$!
                    
                    # Monitor cleanup progress
                    while kill -0 $cleanup_pid 2>/dev/null; do
                      if [ -d "$temp_path" ]; then
                        remaining=$(find "$temp_path" -type f 2>/dev/null | wc -l)
                        echo "Cleanup in progress... $remaining files remaining"
                      fi
                      sleep 10
                    done
                    wait $cleanup_pid
                    echo "Background cleanup completed."
                  else
                    rm -r "$temp_path"
                  fi
                  
                  converted_folders+=("$entry")  # Save the name of the converted folder
                elif [ $validation_result -eq 2 ]; then
                  echo "Validation completed with warnings. Manual verification recommended."
                  echo "Temp directory preserved at: ${mount_point}/${source_path}/${normalized_base_entry}_temp"
                  echo "You can manually remove it after verification."
                  converted_folders+=("$entry")  # Still count as converted since data is there
                else
                  echo "Validation failed. Source and destination do not match adequately."
                  echo "Temp directory preserved for investigation: ${mount_point}/${source_path}/${normalized_base_entry}_temp"
                fi
              elif [ "$cleanup" = "no" ]; then
                echo "Cleanup is disabled. Skipping cleanup for ${entry}"
                converted_folders+=("$entry")
              else
                echo "Rsync encountered an error. Skipping cleanup for ${entry}"
              fi
            else
              echo "Failed to create new dataset ${source_path}/${normalized_base_entry}"
              send_notification "ZFS Dataset Converter" "Dataset Creation Failed" "Failed to create new dataset:
Dataset: ${source_path}/${normalized_base_entry}
Source folder: $entry" "alert" "errors"
            fi
          fi
        else
          echo "Skipping folder ${entry} due to insufficient space"
          available_space=$(numfmt --to=iec $(zfs list -o avail -p -H "${source_path}"))
          required_space=$(numfmt --to=iec $buffer_zone_size)
          send_notification "ZFS Dataset Converter" "Insufficient Space - Folder Skipped" "Skipping folder due to insufficient space:
Folder: $base_entry ($folder_size_hr)
Required: $required_space
Available: $available_space
Path: $entry" "warning" "space_issues"
        fi
      fi
    fi
  done
  
  echo "Completed processing all entries in ${source_path}"
}



#----------------------------------------------------------------------------------    
# this function prints what has been converted
#
print_new_datasets() {
echo "Printing conversion summary..."
if [ ${#converted_folders[@]} -gt 0 ]; then
  echo "The following folders were successfully converted to datasets:"
  for folder in "${converted_folders[@]}"; do
    echo "$folder"
  done
else
  echo "No folders were converted to datasets."
fi
echo "Summary printing completed."
}
    
#----------------------------------------------------------------------------------    
# this function checks if there any folders to covert in the array and if not exits. Also checks sources are valid locations
#
can_i_go_to_work() {
    echo "Checking if anything needs converting"
    
    # Check if the array is empty
    if [ ${#source_datasets_array[@]} -eq 0 ]; then
        echo "No sources are defined."
        echo "If you're expecting to process 'appdata' or VMs, ensure the respective variables are set to 'yes'."
        echo "For other datasets, please add their paths to 'source_datasets_array'."
        echo "No work for me to do. Exiting..."
        send_notification "ZFS Dataset Converter" "Script Configuration Error" "No sources defined for conversion. Check script configuration:
- Set should_process_containers or should_process_vms to 'yes'
- Add paths to source_datasets_array" "alert" "errors"
        exit 1
    fi

    local folder_count=0
    local total_sources=${#source_datasets_array[@]}
    local sources_with_only_datasets=0
    
    for source_path in "${source_datasets_array[@]}"; do
        # Check if source exists
        if [[ ! -e "${mount_point}/${source_path}" ]]; then
            echo "Error: Source ${mount_point}/${source_path} does not exist. Please ensure the specified path is correct."
            send_notification "ZFS Dataset Converter" "Source Path Error" "Source path does not exist: ${mount_point}/${source_path}
Please verify the configuration." "alert" "errors"
            exit 1
        fi
        
        # Check if source is a dataset
        if ! zfs list -o name | grep -q "^${source_path}$"; then
            echo "Error: Source ${source_path} is a folder. Sources must be a dataset to host child datasets. Please verify your configuration."
            send_notification "ZFS Dataset Converter" "Source Dataset Error" "Source must be a dataset, not a folder: ${source_path}
Please verify your configuration." "alert" "errors"
            exit 1
        else
            echo "Source ${source_path} is a dataset and valid for processing ..."
        fi
        
        local current_source_folder_count=0
        for entry in "${mount_point}/${source_path}"/*; do
            base_entry=$(basename "$entry")
            if [ -d "$entry" ] && ! zfs list -o name | grep -q "^${source_path}/$(echo "$base_entry")$"; then

                current_source_folder_count=$((current_source_folder_count + 1))
            fi
        done
        
        if [ "$current_source_folder_count" -eq 0 ]; then
            echo "All children in ${mount_point}/${source_path} are already datasets. No work to do for this source."
            sources_with_only_datasets=$((sources_with_only_datasets + 1))
        else
            echo "Folders found in ${source_path} that need converting..."
        fi
        
        folder_count=$((folder_count + current_source_folder_count))
    done

    if [ "$folder_count" -eq 0 ]; then
        echo "All children in all sources are already datasets. No work to do... Exiting"
        exit 1
    fi
}


#-------------------------------------------------------------------------------------
# this function runs through a loop sending all datasets to process the create_datasets
#
convert() {
echo "Starting conversion process..."
for dataset in "${source_datasets_array[@]}"; do
  echo "Processing dataset: $dataset"
  create_datasets "$dataset"
  echo "Completed processing dataset: $dataset"
done
echo "Conversion process completed."
}

#--------------------------------
#    RUN THE FUNCTIONS          #
#--------------------------------

# Send script start notification
if [ "$dry_run" = "yes" ]; then
  send_notification "ZFS Dataset Converter" "ZFS Dataset Converter Started (DRY RUN)" "Script started in dry run mode. No actual changes will be made." "normal" "script_start"
else
  send_notification "ZFS Dataset Converter" "ZFS Dataset Converter Started" "Script started. Converting folders to ZFS datasets." "normal" "script_start"
fi

echo "Starting main script execution..."

echo "Step 1: Checking if work is needed..."
can_i_go_to_work

echo "Step 2: Stopping Docker containers if needed..."
stop_docker_containers

echo "Step 3: Stopping virtual machines if needed..."
stop_virtual_machines

echo "Step 4: Starting conversion process..."
convert

echo "Step 5: Restarting Docker containers..."
start_docker_containers

echo "Step 6: Restarting virtual machines..."
start_virtual_machines

echo "Step 7: Printing results..."
print_new_datasets

echo "Step 8: Sending completion notifications..."
# Send script completion notification
total_converted=${#converted_folders[@]}
if [ "$total_converted" -gt 0 ]; then
  conversion_list=$(printf '%s\n' "${converted_folders[@]}")
  send_notification "ZFS Dataset Converter" "ZFS Dataset Converter Completed Successfully" "Script completed successfully. $total_converted folders converted to datasets:

$conversion_list" "normal" "script_completion"
  
  # Send conversion summary if enabled
  send_notification "ZFS Dataset Converter" "Conversion Summary: $total_converted Folders Converted" "$conversion_list" "normal" "conversion_summary"
else
  send_notification "ZFS Dataset Converter" "ZFS Dataset Converter Completed" "Script completed. No folders needed conversion - all are already datasets." "normal" "script_completion"
fi

echo "Script execution completed successfully."
echo "All operations finished."

# Clean up any temporary monitoring files
rm -f /tmp/zfs_converter_cleanup.log 2>/dev/null

echo "Final status: Script has completely finished execution."
