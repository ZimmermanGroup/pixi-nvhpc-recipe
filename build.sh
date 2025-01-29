set +x
echo "Starting build.sh"

# set environment variables for non-interactive nvhpc installation
export NVHPC_SILENT="true"
export NVHPC_INSTALL_DIR=$PREFIX
export NVHPC_INSTALL_TYPE="auto"

# run nvhpc installation script
./install

# allow user to troubleshoot build directories before they are cleaned up
# touch WORKING
# while [ -f "WORKING" ]; do
#   sleep 1
# done
# echo "File 'WORKING' no longer exists! Continuing execution..."
