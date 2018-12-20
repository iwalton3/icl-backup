wget https://github.com/zbackup/zbackup/archive/1.4.4.tar.gz
tar -xf 1.4.4.tar.gz
rm 1.4.4.tar.gz
cd zbackup-1.4.4
apt install cmake make libssl-dev libprotobuf-dev protobuf-compiler liblzma-dev liblzo2-dev zlib1g-dev
cmake .
make
make install
cd ../
rm -r zbackup-1.4.4

