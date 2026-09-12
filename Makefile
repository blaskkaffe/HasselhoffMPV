# Wind-Up Fairway - top-level KOS Makefile
#
# Build with the KallistiOS toolchain active:
#   source /opt/toolchains/dc/kos/environ.sh   (or wherever you installed it)
#   make
#
# See README.md for full toolchain setup instructions.

TARGET = windup-fairway.elf

OBJS = src/main.o \
       src/input.o \
       src/car.o \
       src/course.o \
       src/physics.o \
       src/hud.o \
       src/render.o \
       src/game.o

all: rm-elf $(TARGET)

include $(KOS_BASE)/Makefile.rules

clean: rm-elf
	-rm -f $(OBJS)

rm-elf:
	-rm -f $(TARGET)

$(TARGET): $(OBJS)
	kos-cc -o $(TARGET) $(OBJS) -L$(KOS_BASE)/lib -lGL -lGLU -lm

run: $(TARGET)
	$(KOS_LOADER) $(TARGET)

# Building a .cdi for GDEMU/real hardware needs a disc-image tool that
# isn't bundled with KOS itself - see README.md for options (mkdcdisc is
# the easiest). This target assumes mkdcdisc is on your PATH.
cdi: $(TARGET)
	mkdcdisc -e $(TARGET) -o windup-fairway.cdi -n "WINDUP FAIRWAY"

dist: $(TARGET)
	-rm -f $(OBJS)
	$(KOS_STRIP) $(TARGET)

.PHONY: all clean rm-elf run cdi dist
