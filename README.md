#Debian X11 ps / netstat and interface info panel

build like:

gcc -c xshim.c -o xshim.o
nasm -f elf64 hello.asm -o hello.o
gcc -no-pie hello.o xshim.o -o hello $(pkg-config --libs pangocairo cairo) -lX11
./hello

