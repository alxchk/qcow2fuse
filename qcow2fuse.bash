#!/bin/bash

# MIT License
# 
# Copyright (c) 2020 jrwwallis
# https://github.com/jrwwallis/qcow2fuse
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

QEMU_NBD="qemu-nbd"
NBDFUSE="nbdfuse"
FUSE2FS="fuse2fs"

delay=0.2

shopt -s nullglob

function warn () {
    echo "$1" 1>&2
}

function die () {
    warn "$1"
    exit 1
}

function usage () {
    msg=$1
    if [ "$msg" ]; then
	output="${msg}
"
    fi	
    output+="Usage: qcow2fuse.bash [-p PART_ID] imagefile mountpoint
"
    output+="       qcow2fuse.bash -u mountpoint
"
    output+="       qcow2fuse.bash -l imagefile
"
    die "$output"
}

function mnt_pt_hash_tmp () {
    mnt_pt=$1
    abs_mnt_pt=$(readlink -f "${mnt_pt}")
    hash=$(md5sum <<< "$abs_mnt_pt")

    hash="${hash%% *}"
    echo "${XDG_RUNTIME_DIR}/qcow2fuse.${hash}"
}

function qcow2_nbd_mount () {
    tmp_dir=$1
    qcow_file=$2
    offset=$3
    size=$4
    
    image_opts="driver=raw"
    if [ "${offset}" -a "${size}" ]; then
	image_opts+=",offset=${offset}"
	image_opts+=",size=${size}"
    fi
    image_opts+=",file.file.filename=${qcow_file}"
    image_opts+=",file.driver=qcow2"
    ${QEMU_NBD} -k ${tmp_dir}/nbd.sock --image-opts "${image_opts}" 2>&1 | grep -v "Unexpected end-of-file before all bytes were read" &
    
    mkdir ${tmp_dir}/nbd
    ${NBDFUSE} ${tmp_dir}/nbd --unix ${tmp_dir}/nbd.sock &

    until [ -f "${tmp_dir}/nbd/nbd" ]; do
	sleep $delay
    done
}

function qcow2_nbd_unmount () {
    tmp_dir=$1

    until fusermount -u ${tmp_dir}/nbd; do
	sleep $delay
    done
    rmdir ${tmp_dir}/nbd
    while [ -e ${tmp_dir}/nbd.sock ]; do
        sleep $delay
    done    
}

function get_part_params () {
    part_path=$1
    part_id=$2

    {
	# https://alioth-lists.debian.net/pipermail/parted-devel/2006-December/000573.html
	read
	IFS=: read path size type log_sec_sz phy_sec_sz tbl_type model_name
	case $tbl_type in
	loop)
	    die "Not a partitioned image"
	;;
	mbr|gpt)
	;;
	*)
	    die "Indeterminate partitioning"
	esac
	while IFS=: read index start end size fs_type name flags; do
	    if [  "${index}" == "${part_id}" ]; then
		if [[ ${fs_type} =~ ext[234] ]]; then
		    part_start=${start%B}
		    part_size=${size%B}
		    break
		else
		    die "Unknown partition type ${fs_type}"
		fi
	    fi
	done
	if [ -z ${part_start} ]; then
	    die "Partition ${part_id} not found"
	fi
    } < <(parted --machine --script ${tmp_dir}/nbd/nbd unit B print)

    echo "${part_start} ${part_size}"
}

function part_table_type () {
    part_path=$1
 
    {
	# https://alioth-lists.debian.net/pipermail/parted-devel/2006-December/000573.html
	read
	IFS=: read path size type log_sec_sz phy_sec_sz tbl_type model_name
    } < <(parted --machine --script ${tmp_dir}/nbd/nbd unit B print)

    echo "${tbl_type}"
}

function qcow2_ext_mount () {
    tmp_dir=$1
    ${FUSE2FS} ${tmp_dir}/nbd/nbd ${mnt_pt} -o fakeroot | grep -v "Writing to the journal is not supported" || true
}

function qcow2_ext_unmount () {
    mnt_pt="$1"
    fusermount -u "${mnt_pt}"
    while findmnt "${mnt_pt}" > /dev/null; do
	sleep $delay
    done
}

function qcow2_mount_partition () {
    qcow_file=$1
    part_id=$2
    mnt_pt=$3
    
    if findmnt "${mnt_pt}" > /dev/null; then
	die "Mount point ${mnt_pt} already in use"
    fi

    tmp_dir=$(mnt_pt_hash_tmp "${mnt_pt}")
    mkdir -p "${tmp_dir}"

    if findmnt "${tmp_dir}/nbd" > /dev/null; then
	die "${qcow_file} is already mounted"
    fi
    
    qcow2_nbd_mount "${tmp_dir}" "${qcow_file}"

    params=$(get_part_params "${tmp_dir}/nbd/nbd" "${part_id}")
    if [ "${params}" ]; then
	read offset size <<< "${params}"
	qcow2_nbd_unmount "${tmp_dir}"
    else
	qcow2_nbd_unmount "${tmp_dir}"
	rm -rf "${tmp_dir}"
	exit 1
    fi
 
    qcow2_nbd_mount "${tmp_dir}" "${qcow_file}" "${offset}" "${size}"

    qcow2_ext_mount "${tmp_dir}"
}

function qcow2_mount () {
    qcow_file=$1
    mnt_pt=$2
    
    if findmnt "${mnt_pt}" > /dev/null; then
	die "Mount point ${mnt_pt} already in use"
    fi

    tmp_dir=$(mnt_pt_hash_tmp "${mnt_pt}")
    mkdir -p "${tmp_dir}"
    
    if findmnt "${tmp_dir}/nbd" > /dev/null; then
	die "${qcow_file} is already mounted"
    fi
    
    qcow2_nbd_mount "${tmp_dir}" "${qcow_file}"

    tbl_type=$(part_table_type)
    case $tbl_type in
    loop)
    ;;
    mbr|gpt)
        die "Is a ${tbl_type} partitioned image"
    ;;
    *)
	die "Indeterminate partitioning"
    esac

    qcow2_ext_mount "${tmp_dir}"
}

function qcow2_unmount () {
    mnt_pt=$1

    tmp_dir=$(mnt_pt_hash_tmp "${mnt_pt}")
    if ! [ -e "${tmp_dir}" ]; then
	die "No temp dir found for mount point"
    fi
    
    qcow2_ext_unmount "${mnt_pt}"

    qcow2_nbd_unmount "${tmp_dir}"

    while [ -e ${tmp_dir}/nbd.sock ]; do
        sleep $delay
    done
    rm -rf ${tmp_dir}
}

op=mount
while getopts ":p:u:lh" opt; do
    case ${opt} in
    p)
        part_id="$OPTARG"
        ;;
    u)
        op=unmount
	mnt_pt="$OPTARG"
        ;;
    l)
        op=list
        ;;
    h)
        usage
        ;;
    \? )
      usage "Invalid option: $OPTARG"
      ;;
    : )
      usage "Invalid option: $OPTARG requires an argument"
      ;;
    esac
done
shift $((OPTIND -1))

case $op in
mount)
    qcow2_file=$1
    if [ -z "${qcow2_file}" ]; then
	usage
    fi
    mnt_pt=$2
    if [ -z "${mnt_pt}" ]; then
	usage
    fi
    if ! [ -w "${mnt_pt}" ]; then
	die "Directory ${mnt_pt} not writeable"
    fi
    mnt_pt_contents=(${mnt_pt}/*)
    if [ ${#mnt_pt_contents[@]} -ne 0 ]; then
	die "Directory ${mnt_pt} not empty"
    fi
    if [ "${part_id}" ]; then
	qcow2_mount_partition "${qcow2_file}" "${part_id}" "${mnt_pt}"
    else
	qcow2_mount "${qcow2_file}" "${mnt_pt}"
    fi
;;
unmount)
    qcow2_unmount "${mnt_pt}"
;;
list)
    partition_list "${qcow2_file}"
;;
*)
    die "Unsupported operation $op"
esac
