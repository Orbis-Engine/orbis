// Phase-1 placeholder: proves the portable core links into an Android .so.
//
// Replaced by the real JNI bridge to orbis_renderer.h in the next commit;
// kept trivial here so a link failure in this pass can only mean the core
// itself, not anything JNI-shaped.

#include <jni.h>

extern "C" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *, void *) {
  return JNI_VERSION_1_6;
}
