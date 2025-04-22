#! /bin/bash

usage()
{
    # Display Help
    echo
    echo "A helper script to build a python distributions for Python Modules"
    echo
    echo "Syntax: python_build.sh [-h] [options]"
    echo
    echo "Options:"
    echo
    echo "h             Print this Help."
    echo "v <version>   Set the version (default uses the versions specified in setup.py)"
    echo "l             List the current version"
    echo "i             Build inline (default is to copy to a tmp directory)"
    echo "p             Publishes the built module to the private code artifact repository"
    echo "a             The name of the AWS Profile in ~/.aws/credentials that represents the account hosting the Python repo."
    echo "              If this is not passed, the default profile is used. This is used to retrieve the temporay auth token."
    echo "              Even if this fails, the token could still be valid as it has a 12hr expiration."
    echo
}

error_and_exit()
{
    exit_code=${1}
    error_msg=${2}

    echo && \
    echo "${error_msg}" && \
    echo && \
    exit ${exit_code}
}

if [ ${#} == 0 ]; then
    usage
    exit 0
fi

while getopts ":h" option; do
    case ${option} in
        h) # display Help
            usage
            exit 0
    esac
done

MODULE="flaskoidc"
SOURCE_DIR="."

INLINE="FALSE"
VERSION=
LIST=
PUBLISH=
PUBLISH_DIR=
AWS_PROFILE_PYTHON_REPO=

####
#   Builds a Python Distribution
####
build()
{
    if [ ! -d "${SOURCE_DIR}" ]; then
        error_and_exit 201 "ERROR: SOURCE_DIR is not a valid directory"
    fi

    if [ "${INLINE}" == "FALSE" ]; then
        TMP_DIR="/tmp/${MODULE}_build"

        # Cleanup
        echo "  Cleanup old build dir..."
        rm -rf ${TMP_DIR}

        # Create working dir
        echo "  Setup new build dir..."
        mkdir -p ${TMP_DIR}

        # Copy module into working dir
        echo "  Copying module source into build dir..."
        cp -LR ${SOURCE_DIR} ${TMP_DIR}

        cp version.txt ${TMP_DIR}

        BUILD_DIR="${TMP_DIR}/$(basename ${SOURCE_DIR})"
    else
        # Cleanup any prior builds
        rm -rf ${SOURCE_DIR}/dist
        rm -rf ${SOURCE_DIR}/build
        rm -rf ${SOURCE_DIR}/*.egg-info

        BUILD_DIR=${SOURCE_DIR}
    fi

    # Edit the setup.py to override the version
    cd ${BUILD_DIR}
    if [ "${VERSION}" != "" ]; then
        echo "  Overriding __version__..."
        echo "${VERSION}" > ../version.txt
    fi

    # Create wheel
    echo "  Building wheel..."
    export PYTHONWARNINGS="ignore" # Suppresses the deprecation warning. We know we need to stop using setup.py
    python setup.py -q bdist_wheel --universal > /dev/null
    if [ ${?} -ne 0 ]; then
        error_and_exit 202 "ERROR: Failed to build wheel ^^^"
    fi

    PUBLISH_DIR="${PWD}/dist"

    echo "  \$\$\$ Wheel can be found here: ${PUBLISH_DIR} \$\$\$"
}

publish()
{
    echo && echo "IMPORTANT: Before you can connect to this repository, you must install twine, the AWS CLI, and configure your AWS credentials" && echo

    # Login
    echo "  Setting up twine with repo..."
    AWS_PROFILE_PYTHON_REPO_OPTION=
    if [ "${AWS_PROFILE_PYTHON_REPO}" != "" ]; then
        AWS_PROFILE_PYTHON_REPO_OPTION="--profile ${AWS_PROFILE_PYTHON_REPO} --region us-east-1"
    fi

    aws codeartifact login ${AWS_PROFILE_PYTHON_REPO_OPTION} --tool twine --repository foodtruck.python.artifact.repository --domain foodtruck-codeartifact-domain --domain-owner 812753953378
    if [ ${?} -ne 0 ]; then
        error_and_exit 301 "ERROR: Failed to login to AWS CodeArtifact and setup twine"
    fi

    if [ ! -d "${PUBLISH_DIR}" ]; then
        error_and_exit 302 "ERROR: PUBLISH_DIR is not a valid directory"
    fi

    echo "  Publishing..."
    twine upload --repository codeartifact ${PUBLISH_DIR}/*
    if [ ${?} -ne 0 ]; then
        if [ "${OVERWRITE}" != "" ]; then
            echo "  Overwriting..."
            BUILT_VERSION="$(sed -n -e 's/^.*__version__.*= //p' ${BUILD_DIR}/setup.py | sed 's/\"//g')"
            aws codeartifact delete-package-versions ${AWS_PROFILE_PYTHON_REPO_OPTION} --domain foodtruck-codeartifact-domain --repository foodtruck.python.artifact.repository --format pypi --package ${MODULE} --versions ${BUILT_VERSION}
            if [ ${?} -ne 0 ]; then
                error_and_exit 401 "FAILED: Overwrite did not work"
                exit 1
            else
                twine upload --repository codeartifact ${PUBLISH_DIR}/*
            fi
        else
            error_and_exit 402 "ERROR: twine upload failed ^^^"
        fi
    fi
}

OVERWRITE=

OPTIND=1
while getopts ":v:lpia:o" option; do
    case ${option} in
        v) # Set Version
            VERSION=${OPTARG}
            ;;
        l) # List Version
            # echo  && echo "Current wheel version is $(sed -n -e 's/^.*__version__.*= //p' ${SOURCE_DIR}/setup.py)" && echo
            echo  && echo "Current wheel version is $(cat version.txt)" && echo
            exit 0
            ;;
        p) # Publish Wheel
            PUBLISH="TRUE"
            ;;
        i) # Inline
            INLINE="TRUE"
            ;;
        a) # AWS Profile Name
            AWS_PROFILE_PYTHON_REPO=${OPTARG}
            ;;
        o) # Overwrite
            OVERWRITE="TRUE"
            ;;
        *)
            usage
            error_and_exit 111 "ERROR: Unexpected option passed to command 'wheel'': ${option}"
            ;;
    esac
done

build
if [ "${PUBLISH}" != "" ]; then
    publish
fi

echo "Done!"
