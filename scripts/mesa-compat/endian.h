/* macOS has no <endian.h>, yet Mesa's cross configure decides it does; give
 * u_endian.h the glibc-style macros it looks for. Only used for the x86_64
 * KosmicKrisp build (scripts/build-kosmickrisp.sh). */
#include <machine/endian.h>
#define __BYTE_ORDER    BYTE_ORDER
#define __LITTLE_ENDIAN LITTLE_ENDIAN
#define __BIG_ENDIAN    BIG_ENDIAN
