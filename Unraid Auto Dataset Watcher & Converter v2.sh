#!/bin/bash
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# #   Script for watching a dataset and auto updating regular folders converting them to datasets
# #   (needs Unraid 6.12 or above)
# #   by - SpaceInvaderOne
#set -x

## Please consider this script in beta at the moment.
## new functions:
##   - Auto stop only docker containers whose appdata is not ZFS based
##   - Auto stop only VMs whose vdisk folder is not a dataset
##   - Add extra datasets to auto update via source_datasets_array
##   - Normalises German umlauts into ASCII
##   - Various safety and other checks

# ---------------------------------------
# Main Variables
# ---------------------------------------

# real run or dry run
# Set to "yes" for a dry run. Change to "no" to run for real
dry_run="no"

# Process Docker Containers?
# set to "yes" to process and convert appdata folders into ZFS datasets
should_process_containers="no"
# source pool and dataset names for Docker appdata
source_pool_where_appdata_is="sg1_storage"
source_dataset_where_appdata_is="appdata"

# Process Virtual Machines?
# set to "yes" to process and convert VM vdisk folders into ZFS datasets
should_process_vms="no"
# source pool and dataset names for VM domains
source_pool_where_vm_domains_are="darkmatter_disks"
source_dataset_where_vm_domains_are="domains"
# how long to wait (seconds) before forcing VM shutdown
vm_forceshutdown_wait="90"

# Additional User-Defined Datasets
# Add more entries as "pool/dataset" strings inside the parentheses
source_datasets_array=(
  # "tank/mydata"
)

# Cleanup temporary folders after successful copy?
cleanup="yes"
# Replace spaces in folder names with underscores when creating datasets?
replace_spaces="no"

# ---------------------------------------
# Advanced Variables - No need to modify
# ---------------------------------------

# If Docker container processing is enabled, add its path to the sources array
if [[ "$should_process_containers" =~ ^[Yy]es$ ]]; then
    source_datasets_array+=("${source_pool_where_appdata_is}/${source_dataset_where_appdata_is}")
    source_path_appdata="$source_pool_where_appdata_is/$source_dataset_where_appdata_is"
fi

# If VM processing is enabled, add its path to the sources array
if [[ "$should_process_vms" =~ ^[Yy]es$ ]]; then
    source_datasets_array+=("${source_pool_where_vm_domains_are}/${source_dataset_where_vm_domains_are}")
    source_path_vms="$source_pool_where_vm_domains_are/$source_dataset_where_vm_domains_are"
fi

# Mount point for all pools
mount_point="/mnt"
# Arrays to track stopped containers and VMs for later restart
stopped_containers=()
stopped_vms=()
# Array to track which folders were successfully converted\ converted_folders=()
# Percentage of folder size to reserve as buffer when creating new dataset
buffer_zone=11

#--------------------------------
#     FUNCTIONS START HERE      #
#--------------------------------

#----------------------------------------------------------------
# find_real_location: given a /mnt/user/... path, returns the real /mnt/diskX/... path
#----------------------------------------------------------------
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

#----------------------------------------------------------------
# is_zfs_dataset: checks if given location is a mounted ZFS dataset
# returns 0 if yes, 1 otherwise
#----------------------------------------------------------------
is_zfs_dataset() {
  local location="$1"
  if zfs list -H -o mounted,mountpoint | grep -q "^yes\t$location$"; then
    return 0
  else
    return 1
  fi
}

#----------------------------------------------------------------
# stop_docker_containers: stops containers whose appdata is a folder
# rather than a ZFS dataset, so they can be converted
#----------------------------------------------------------------
stop_docker_containers() {
  if [[ "$should_process_containers" != "yes" ]]; then
    return
  fi
  echo "Checking Docker containers..."

  for container in $(docker ps -q); do
    local cname=$(docker inspect --format '{{.Name}}' $container | cut -c2-)
    local binds=$(docker inspect --format '{{ range .Mounts }}{{ if eq .Type "bind" }}{{ .Source }}\n{{ end }}{{ end }}' $container)
    local to_stop=false

    # check each bind mount
    while IFS= read -r src; do
      [[ -z $src ]] && continue
      if [[ $src == /mnt/user/* ]]; then
        src=$(find_real_location "$src") || continue
      fi
      # only consider appdata paths
      if [[ $src =~ ^/mnt/$source_path_appdata ]]; then
        local child=${src#/mnt/$source_path_appdata/}
        child=${child%%/*}
        if ! is_zfs_dataset "/mnt/$source_path_appdata/$child"; then
          echo "Container $cname uses folder appdata. Stopping container to convert."
          to_stop=true
          break
        fi
      fi
    done <<< "$binds"

    if $to_stop; then
      docker stop "$container"
      stopped_containers+=("$cname")
    fi
  done
}

#----------------------------------------------------------------
# start_docker_containers: restarts any containers we stopped earlier
#----------------------------------------------------------------
start_docker_containers() {
  for c in "${stopped_containers[@]}"; do
    echo "Restarting container $c..."
    [[ "$dry_run" != "yes" ]] && docker start "$c"
  done
}

#----------------------------------------------------------------
# get_dataset_path: strips the final component from a full path,
# leaving the parent dataset path
#----------------------------------------------------------------
get_dataset_path() {
  local full="$1"
  echo "$full" | rev | cut -d'/' -f2- | rev
}

#----------------------------------------------------------------
# get_vm_disk: retrieves VM disk path for given libvirt VM
#----------------------------------------------------------------
get_vm_disk() {
  local vm="$1"
  echo "Fetching disk for VM: $vm" >&2
  local target=$(virsh domblklist "$vm" --details | grep disk | awk '{print $3}')
  if [[ -n $target ]]; then
    local disk=$(virsh domblklist "$vm" | grep "$target" | awk '{$1="";print $0}' | sed 's/^[ \t]*//;s/[ \t]*$//')
    echo "$disk"
    return 0
  else
    echo "No disk found for VM: $vm" >&2
    return 1
  fi
}

#----------------------------------------------------------------
# stop_virtual_machines: stops VMs whose vdisk is a folder, not dataset
#----------------------------------------------------------------
stop_virtual_machines() {
  if [[ "$should_process_vms" != "yes" ]]; then
    return
  fi
  echo "Checking running VMs..."

  while IFS= read -r vm; do
    [[ -z $vm ]] && continue
    local disk=$(get_vm_disk "$vm") || continue
    if [[ $disk == /mnt/user/* ]]; then
      disk=$(find_real_location "$disk") || continue
    fi
    if [[ $disk =~ ^/mnt/$source_path_vms ]]; then
      # extract child folder name
      local child=$(basename $(get_dataset_path "$disk"))
      if ! is_zfs_dataset "/mnt/$source_path_vms/$child"; then
        echo "Stopping VM $vm for conversion of vdisk."
        virsh shutdown "$vm"
        stopped_vms+=("$vm")
      fi
    fi
  done < <(virsh list --name | grep -v '^$')
}

#----------------------------------------------------------------
# start_virtual_machines: restarts any VMs we stopped earlier
#----------------------------------------------------------------
start_virtual_machines() {
  for v in "${stopped_vms[@]}"; do
    echo "Starting VM $v..."
    [[ "$dry_run" != "yes" ]] && virsh start "$v"
  done
}

#----------------------------------------------------------------
# normalize_name: convert German umlauts to ASCII equivalents
#----------------------------------------------------------------
normalize_name() {
  local name="$1"
  echo "$name" | sed 's/ä/ae/g; s/ö/oe/g; s/ü/ue/g; s/Ä/Ae/g; s/Ö/Oe/g; s/Ü/Ue/g; s/ß/ss/g'
}

#----------------------------------------------------------------
# create_datasets: main conversion function
# 1) Resume partial copies from *_temp folders
# 2) Convert any new folders into ZFS datasets + rsync
#----------------------------------------------------------------
create_datasets() {
  local source_path="$1"

  # --- Resume interrupted copies ---
  for tmp in "${mount_point}/${source_path}"/*_temp; do
    [[ -d $tmp ]] || continue
    local base=$(basename "$tmp" _temp)
    local dataset="${source_path}/${base}"
    if zfs list -H -o name | grep -q "^${dataset}$"; then
      echo "Resuming copy for ${base}_temp → ${dataset}"
      # Calculate remaining data to copy
      temp_size=$(du -sb "$tmp" | cut -f1)
      dest_dir="${mount_point}/${dataset}"
      dest_size=$(du -sb "$dest_dir" | cut -f1)
      remaining=$((temp_size - dest_size))
      buffer_needed=$((remaining * buffer_zone / 100))
      avail=$(zfs list -H -o avail -p -H "${source_path}")
      if (( avail < buffer_needed )); then
        echo "Skipping resume: insufficient space for remaining $(numfmt --to=iec $remaining) (need approx $(numfmt --to=iec $buffer_needed), have $(numfmt --to=iec $avail))."
        continue
      fi
      rsync -a "$tmp/" "$dest_dir/"
      [[ "$cleanup" == "yes" ]] && rm -rf "$tmp"
    fi
  done

  # --- Convert new folders ---
  for entry in "${mount_point}/${source_path}"/*; do
    local folder=$(basename "$entry")
    [[ "$folder" == *_temp ]] && continue

    # optionally replace spaces
    local clean_folder=${folder// /_}
    local norm_folder=$(normalize_name "$clean_folder")

    # skip if dataset already exists
    if zfs list -H -o name | grep -q "^${source_path}/${norm_folder}$"; then
      echo "Skipping existing dataset: ${norm_folder}"
      continue
    fi

    if [[ -d $entry ]]; then
      echo "Processing folder: ${folder}"
      # get size
      local size_bytes=$(du -sb "$entry" | cut -f1)
      local size_human=$(du -sh "$entry" | cut -f1)
      echo "Folder size: $size_human"
      local buffer_size=$((size_bytes * buffer_zone / 100))

      # check available space
      local avail=$(zfs list -H -o avail -p -H "${source_path}")
      if (( avail >= buffer_size )); then
        echo "Creating dataset ${source_path}/${norm_folder}";
        mv "$entry" "${mount_point}/${source_path}/${norm_folder}_temp"
        if zfs create "${source_path}/${norm_folder}"; then
          rsync -a "${mount_point}/${source_path}/${norm_folder}_temp/" "${mount_point}/${source_path}/${norm_folder}/"
          # cleanup temp if successful
          if [[ "$cleanup" == "yes" ]]; then
            rm -rf "${mount_point}/${source_path}/${norm_folder}_temp"
          fi
          converted_folders+=("${folder}")
        else
          echo "Failed to create dataset ${source_path}/${norm_folder}";
        fi
      else
        echo "Skipping ${folder}: insufficient space (need ~$buffer_size, have $avail)"
      fi
    fi
  done
}

#----------------------------------------------------------------
# print_new_datasets: report summary of converted folders
#----------------------------------------------------------------
print_new_datasets() {
  if [[ ${#converted_folders[@]} -gt 0 ]]; then
    echo "Successfully converted the following folders to datasets:"
    printf '  - %s\n' "${converted_folders[@]}"
  else
    echo "No folders were converted."
  fi
}

#----------------------------------------------------------------
# can_i_go_to_work: ensure there is work to do and sources exist
#----------------------------------------------------------------
can_i_go_to_work() {
  if [[ ${#source_datasets_array[@]} -eq 0 ]]; then
    echo "No sources are defined. Exiting."; exit 1
  fi
  for src in "${source_datasets_array[@]}"; do
    if [[ ! -d "${mount_point}/${src}" ]]; then
      echo "Source ${mount_point}/${src} not found. Please check your configuration."; exit 1
    fi
  done
}

# Run sequence
can_i_go_to_work
stop_docker_containers
stop_virtual_machines\# Missing function call
convert(){ for ds in "${source_datasets_array[@]}"; do create_datasets "$ds"; done; }
convert
start_docker_containers
start_virtual_machines
print_new_datasets
