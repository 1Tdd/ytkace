#include "MP4TextStyle.h"

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    return YTKACEMP4::patchTextStyle(argv[1], 1920, 1080) ? 0 : 1;
}
