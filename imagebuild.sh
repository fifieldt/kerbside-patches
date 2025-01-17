#!/bin/bash -e

# Ensure we fail even when piping output to ts
set -o pipefail

# Note that our CI environment requires these packages to be installed.
#     From the OS: git moreutils python3-venv
#     From pypi: tox

topdir=$(pwd)
topsrcdir="${topdir}/src"

# Color helpers, from https://stackoverflow.com/questions/5947742/
Color_Off='\033[0m'       # Text Reset
Red='\033[0;31m'          # Red
Green='\033[0;32m'        # Green
Yellow='\033[0;33m'       # Yellow
Blue='\033[0;34m'         # Blue
Purple='\033[0;35m'       # Purple
Cyan='\033[0;36m'         # Cyan
White='\033[0;37m'        # White

# And an arrow!
Arrow='\u2192'

H1="${Green}"
H2="${Blue}"
H3="${Arrow}${Purple}"

function on_exit {
    echo
    echo -e "${Red}*** Failed ***${No_Color}"
    echo
    }
trap 'on_exit $?' EXIT

. buildconfig.sh

echo
echo -e "${H1}==================================================${Color_Off}"
echo -e "${H1}Preparing artifacts from previous stages${Color_Off}"
echo -e "${H1}==================================================${Color_Off}"

projects=$(find . -type f -name "config.yaml" | cut -f 2 -d "/")
declare -a directories
mkdir -p ${topsrcdir}
for project in kerbside ${projects}; do
    if [ ${project} == "kerbside" ]; then
        directory="kerbside"
    else
        directory=$(yq -r .directory ${project}/config.yaml)
    fi

    if [ ! -e ${topsrcdir}/${directory} ]; then
        echo -e "${H2}Extract ${directory}.tgz for ${project} ${Color_Off}"
        tar xzf ${topsrcdir}/${directory}.tgz -C ${topsrcdir}/
        directories+=(${directory})
    else
        echo -e "${H2}${project} shares ${directory}${Color_Off}"
    fi
done

echo
echo -e "${H1}==================================================${Color_Off}"
echo -e "${H1}State of build dependancies${Color_Off}"
echo -e "${H1}==================================================${Color_Off}"
du -sh ${topsrcdir}/*

# Docker image build steps, which are pre target branch
for target in ${build_targets}; do
    echo
    echo -e "${H1}==================================================${Color_Off}"
    echo -e "${H1}Building docker images for ${target}${Color_Off}"
    echo -e "${H1}==================================================${Color_Off}"

    if [ ${target} == "master" ]; then
        target_branch="master-patches"
    else
        target_branch="stable/${target}-patches"
    fi
    echo -e "${H2}Target branch is ${target_branch}${Color_Off}"

    # Checkout the target branch in all our directories. Kerbside is a special
    # case as it doesn't obey the OpenStack branch naming conventions.
    for directory in "${directories[@]}"; do
        if [ ${directory} == "kerbside" ]; then
            tb="develop"
        elif [ ${directory} == "nova-specs" ]; then
            tb="master"
        else
            tb="${target_branch}"
        fi

        echo -e "${H2}${Arrow}Checkout ${tb} in ${directory}${Color_Off}"
        pushd ${topsrcdir}/${directory}
        git checkout ${tb}
        popd
    done

    # Create a venv
    venvdir="${topdir}/venv-${target_branch}"
    if [ ! -f ${venvdir}/bin/activate ]; then
        rm -rf ${venvdir}
        echo
        echo -e "${H2}Create build venv${Color_Off}"
        python3 -mvenv "${venvdir}"
    else
        echo -e "${H2}Using existing build venv ${venvdir}${Color_Off}"
    fi

    # Install kolla, docker and oslo
    if [ ! -f ${venvdir}/bin/kolla-build ]; then
        # We need to override the version of oslo.config so that it doesn't get clobbered
        # by the Kolla install
        export PBR_VERSION=10.0.0
        ${venvdir}/bin/pip install "${topsrcdir}/oslo.config"
        unset PBR_VERSION

        ${venvdir}/bin/pip install "${topsrcdir}/kolla"
        ${venvdir}/bin/pip install docker
    else
        echo -e "${H2}Using existing kolla install in ${venvdir}${Color_Off}"
    fi

    # Customize the kolla-build.conf file
    echo
    echo -e "${H2}Customize build configuration${Color_Off}"
    cat kolla-build.conf.in | \
        sed "s|TOPSRCDIR|${topsrcdir}|g" \
        > kolla-build.conf

    # Build images
    echo
    echo -e "${H2}Build images${Color_Off}"
    cd ${topsrcdir}
    ${venvdir}/bin/kolla-build \
        --config-file "${topdir}/kolla-build.conf" \
        --tag ${target}-${CI_COMMIT_SHORT_SHA} \
        --namespace kolla \
        nova-compute nova-libvirt nova-api kerbside| ts "%b %d %H:%M:%S ${target}"
    cd ${topdir}
done

trap - EXIT

echo -e "${H1}==================================================${Color_Off}"
echo -e "${H1}All docker images built correctly.${Color_Off}"
echo -e "${H1}==================================================${Color_Off}"
