RUBYOPT='' './gen_bridge_metadata' \
  --format complete  \
  --cflags "-I. -I./header -I'.'" \
  --headers "sample.txt" \
  -o 'sample.bridgesupport'
