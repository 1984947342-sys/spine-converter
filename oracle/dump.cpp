// Pose dumper for the 3.7 to 4.2 runtimes, SPINE_VERSION is major * 100 + minor
// Output matches dump_4.3.cpp
#include <spine/spine.h>

#include <locale.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

using namespace spine;

namespace spine {
SpineExtension *getDefaultExtension() {
    return new DefaultSpineExtension();
}
} // namespace spine

class NoTextureLoader : public TextureLoader {
  public:
    void load(AtlasPage &, const String &) override {}
    void unload(void *) override {}
};

static const float sample_rate = 30;

#if SPINE_VERSION >= 308
#define ATLAS_TEXTURES , false
#else
#define ATLAS_TEXTURES
#endif

static void printFloat(float value) {
    if (isfinite(value))
        printf("%.9g", value);
    else
        printf("null");
}

static void printString(const String &value) {
    putchar('"');
    for (const char *c = value.buffer(); c && *c; c++) {
        if (*c == '"' || *c == '\\')
            printf("\\%c", *c);
        else if ((unsigned char)*c < 0x20)
            printf("\\u%04x", *c);
        else
            putchar(*c);
    }
    putchar('"');
}

static void printNames(const char *key, Vector<Bone *> &bones) {
    printf("\"%s\":[", key);
    for (size_t i = 0; i < bones.size(); i++) {
        if (i) putchar(',');
        printString(bones[i]->getData().getName());
    }
    putchar(']');
}

static void printNames(const char *key, Vector<Slot *> &slots) {
    printf("\"%s\":[", key);
    for (size_t i = 0; i < slots.size(); i++) {
        if (i) putchar(',');
        printString(slots[i]->getData().getName());
    }
    putchar(']');
}

static void printNames(const char *key, Vector<Skin *> &skins) {
    printf("\"%s\":[", key);
    for (size_t i = 0; i < skins.size(); i++) {
        if (i) putchar(',');
        printString(skins[i]->getName());
    }
    putchar(']');
}

/** Skin bones start with 3.8 */
static bool isActive(Bone &bone) {
#if SPINE_VERSION >= 308
    return bone.isActive();
#else
    (void)bone;
    return true;
#endif
}

/** Negative delta restarts physics */
static void updateWorldTransform(Skeleton &skeleton, float delta) {
#if SPINE_VERSION >= 402
    if (!getenv("ORACLE_PHYSICS")) return skeleton.updateWorldTransform(Physics_None);
    Vector<PhysicsConstraint *> &constraints = skeleton.getPhysicsConstraints();
    for (size_t i = 0; delta < 0 && i < constraints.size(); i++) constraints[i]->reset();
    skeleton.update(delta < 0 ? 0 : delta);
    skeleton.updateWorldTransform(Physics_Update);
#else
    (void)delta;
    skeleton.updateWorldTransform();
#endif
}

static void printVertices(Slot &slot, Vector<float> &buffer) {
    // inactive bones keep stale world transforms
    if (!isActive(slot.getBone())) {
        printf("null");
        return;
    }
    Attachment *attachment = slot.getAttachment();
    size_t count = 0;
    if (attachment && attachment->getRTTI().isExactly(RegionAttachment::rtti)) {
        RegionAttachment *region = static_cast<RegionAttachment *>(attachment);
        count = 8;
        buffer.setSize(count, 0);
#if SPINE_VERSION >= 401
        region->computeWorldVertices(slot, buffer, 0, 2);
#else
        region->computeWorldVertices(slot.getBone(), buffer, 0, 2);
#endif
    } else if (attachment && attachment->getRTTI().instanceOf(VertexAttachment::rtti)) {
        VertexAttachment *vertices = static_cast<VertexAttachment *>(attachment);
        count = vertices->getWorldVerticesLength();
        buffer.setSize(count, 0);
        vertices->computeWorldVertices(slot, 0, count, buffer, 0, 2);
    }
    putchar('[');
    for (size_t i = 0; i < count; i++) {
        if (i) putchar(',');
        printFloat(buffer[i]);
    }
    putchar(']');
}

static const int clip_cells = 4;

/** Covered fraction of each cell of a grid over the clipping polygon bounds */
static void printClip(Slot &slot) {
    Attachment *attachment = isActive(slot.getBone()) ? slot.getAttachment() : nullptr;
    if (!attachment || !attachment->getRTTI().isExactly(ClippingAttachment::rtti)) {
        printf("null");
        return;
    }
    ClippingAttachment *clip = static_cast<ClippingAttachment *>(attachment);
    size_t n = clip->getWorldVerticesLength();
    Vector<float> world;
    world.setSize(n, 0);
    clip->computeWorldVertices(slot, 0, n, world, 0, 2);
    float minX = world[0], minY = world[1], maxX = world[0], maxY = world[1];
    for (size_t i = 2; i < n; i += 2) {
        minX = fminf(minX, world[i]);
        maxX = fmaxf(maxX, world[i]);
        minY = fminf(minY, world[i + 1]);
        maxY = fmaxf(maxY, world[i + 1]);
    }
    SkeletonClipping clipper;
    if (clipper.clipStart(slot, clip) == 0) {
        printf("[]");
        return;
    }
    float w = (maxX - minX) / clip_cells, h = (maxY - minY) / clip_cells;
    unsigned short triangles[] = {0, 1, 2, 0, 2, 3};
    putchar('[');
    for (int cell = 0; cell < clip_cells * clip_cells; cell++) {
        float x = minX + w * (cell % clip_cells), y = minY + h * (cell / clip_cells);
        float quad[] = {x, y, x + w, y, x + w, y + h, x, y + h};
        float uvs[8] = {0};
        clipper.clipTriangles(quad, triangles, 6, uvs, 2);
        Vector<float> &v = clipper.getClippedVertices();
        Vector<unsigned short> &t = clipper.getClippedTriangles();
        float area = 0;
        for (size_t i = 0; i < t.size(); i += 3) {
            float ax = v[t[i] * 2], ay = v[t[i] * 2 + 1];
            float bx = v[t[i + 1] * 2], by = v[t[i + 1] * 2 + 1];
            float cx = v[t[i + 2] * 2], cy = v[t[i + 2] * 2 + 1];
            area += fabsf((bx - ax) * (cy - ay) - (cx - ax) * (by - ay)) / 2;
        }
        if (cell) putchar(',');
        printFloat(w * h > 0 ? area / (w * h) : 0);
    }
    putchar(']');
    clipper.clipEnd();
}

static void printEvents(Vector<Event *> &events) {
    printf(",\"events\":[");
    for (size_t i = 0; i < events.size(); i++) {
        Event &event = *events[i];
        if (i) putchar(',');
        putchar('[');
        printString(event.getData().getName());
        printf(",%d,", event.getIntValue());
        printFloat(event.getFloatValue());
        putchar(',');
        printString(event.getStringValue());
        putchar(',');
        printFloat(event.getVolume());
        putchar(',');
        printFloat(event.getBalance());
        putchar(',');
        printFloat(event.getTime());
        putchar(',');
#if SPINE_VERSION >= 308
        printString(event.getData().getAudioPath());
#else
        printString(const_cast<EventData &>(event.getData()).getAudioPath());
#endif
        putchar(']');
    }
    putchar(']');
}

static void printSample(
    Skeleton &skeleton,
    const String &skin,
    const String &animation,
    float time,
    Vector<Event *> *events,
    Vector<float> &buffer
) {
    printf("{\"skin\":");
    printString(skin);
    printf(",\"animation\":");
    printString(animation);
    printf(",\"time\":");
    printFloat(time);
    if (events) printEvents(*events);

    printf(",\"bones\":[");
    Vector<Bone *> &bones = skeleton.getBones();
    for (size_t i = 0; i < bones.size(); i++) {
        Bone &bone = *bones[i];
        if (i) putchar(',');
        if (!isActive(bone)) {
            printf("null");
            continue;
        }
        float values[] = {
            bone.getA(),
            bone.getB(),
            bone.getC(),
            bone.getD(),
            bone.getWorldX(),
            bone.getWorldY()
        };
        putchar('[');
        for (int v = 0; v < 6; v++) {
            if (v) putchar(',');
            printFloat(values[v]);
        }
        putchar(']');
    }

    printf("],\"slots\":[");
    Vector<Slot *> &slots = skeleton.getSlots();
    for (size_t i = 0; i < slots.size(); i++) {
        Slot &slot = *slots[i];
        if (i) putchar(',');
        printf("{\"attachment\":");
        if (slot.getAttachment())
            printString(slot.getAttachment()->getName());
        else
            printf("null");
        Color &color = slot.getColor();
        printf(",\"color\":[");
        printFloat(color.r);
        putchar(',');
        printFloat(color.g);
        putchar(',');
        printFloat(color.b);
        putchar(',');
        printFloat(color.a);
        printf("],\"dark\":");
        if (slot.hasDarkColor()) {
            Color &dark = slot.getDarkColor();
            putchar('[');
            printFloat(dark.r);
            putchar(',');
            printFloat(dark.g);
            putchar(',');
            printFloat(dark.b);
            putchar(']');
        } else {
            printf("null");
        }
#if SPINE_VERSION >= 401
        Attachment *attachment = slot.getAttachment();
        Sequence *sequence = nullptr;
        if (attachment && attachment->getRTTI().isExactly(RegionAttachment::rtti))
            sequence = static_cast<RegionAttachment *>(attachment)->getSequence();
        else if (attachment && attachment->getRTTI().instanceOf(MeshAttachment::rtti))
            sequence = static_cast<MeshAttachment *>(attachment)->getSequence();
        if (sequence) {
            int index = slot.getSequenceIndex() == -1 ? sequence->getSetupIndex() : slot.getSequenceIndex();
            int last = (int) sequence->getRegions().size() - 1;
            printf(",\"sequence\":%d", index < last ? index : last);
        }
#endif
        printf(",\"vertices\":");
        printVertices(slot, buffer);
        printf(",\"clip\":");
        printClip(slot);
        putchar('}');
    }

    printf("],\"drawOrder\":[");
    Vector<Slot *> &order = skeleton.getDrawOrder();
    for (size_t i = 0; i < order.size(); i++) {
        if (i) putchar(',');
        printf("%d", order[i]->getData().getIndex());
    }
    printf("]}\n");
}

static int printAtlas(Atlas &atlas) {
    Vector<AtlasPage *> &pages = atlas.getPages();
    if (pages.size() == 0) {
        fprintf(stderr, "atlas has no pages\n");
        return 1;
    }
    for (size_t i = 0; i < pages.size(); i++) {
        AtlasPage &page = *pages[i];
#if SPINE_VERSION >= 400
        bool pma = page.pma;
#else
        bool pma = false;
#endif
        printf("page\t");
        printString(page.name);
        printf(
            "\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n",
            page.width,
            page.height,
            (int)page.format,
            (int)page.minFilter,
            (int)page.magFilter,
            (int)page.uWrap,
            (int)page.vWrap,
            (int)pma
        );
    }
    Vector<AtlasRegion *> &regions = atlas.getRegions();
    for (size_t i = 0; i < regions.size(); i++) {
        AtlasRegion &region = *regions[i];
        size_t p = 0;
        while (pages[p] != region.page) p++;
        printf("region\t%d\t", (int)p);
        printString(region.name);
        printf("\t%d\t%d\t%d\t%d", region.x, region.y, region.width, region.height);
        float floats[] = {region.u, region.v, region.u2, region.v2, region.offsetX, region.offsetY};
        for (int f = 0; f < 6; f++) {
            putchar('\t');
            printFloat(floats[f]);
        }
        printf(
            "\t%d\t%d\t%d\t%d\t",
            region.originalWidth,
            region.originalHeight,
#if SPINE_VERSION >= 308
            region.degrees,
#else
            region.rotate ? 90 : 0,
#endif
            region.index
        );
#if SPINE_VERSION >= 400
        for (size_t n = 0; n < region.names.size(); n++) {
            if (n) putchar(',');
            printf("%s", region.names[n].buffer());
        }
        putchar('\t');
        for (size_t v = 0; v < region.values.size(); v++) {
            if (v) putchar(',');
            printFloat(region.values[v]);
        }
#else
        // 4.x keeps split and pad as named values
        printf("%s", region.splits.size() ? (region.pads.size() ? "split,pad" : "split") : "");
        putchar('\t');
        for (size_t v = 0; v < region.splits.size() + region.pads.size(); v++) {
            if (v) putchar(',');
            size_t splits = region.splits.size();
            printf("%d", v < splits ? region.splits[v] : region.pads[v - splits]);
        }
#endif
        putchar('\n');
    }
    return 0;
}

int main(int argc, char **argv) {
    setlocale(LC_ALL, "C");
    NoTextureLoader textureLoader;
    if (argc == 2) {
        Atlas atlas(argv[1], &textureLoader ATLAS_TEXTURES);
        return printAtlas(atlas);
    }
    if (argc != 3) {
        fprintf(stderr, "usage: %s <skeleton.json|skeleton.skel> <atlas>\n", argv[0]);
        fprintf(stderr, "       %s <atlas>\n", argv[0]);
        return 2;
    }
    Bone::setYDown(false);

    Atlas atlas(argv[2], &textureLoader ATLAS_TEXTURES);
    SkeletonData *data;
    String error;
    size_t length = strlen(argv[1]);
    // .json and .spine-json
    if (length >= 4 && strcmp(argv[1] + length - 4, "json") == 0) {
        SkeletonJson json(&atlas);
        data = json.readSkeletonDataFile(argv[1]);
        error = json.getError();
    } else {
        SkeletonBinary binary(&atlas);
        data = binary.readSkeletonDataFile(argv[1]);
        error = binary.getError();
    }
    if (!data) {
        fprintf(stderr, "%s\n", error.buffer());
        return 1;
    }

    Skeleton skeleton(data);
    const char *flip = getenv("ORACLE_FLIP");
    if (flip && strchr(flip, 'x')) skeleton.setScaleX(-1);
    if (flip && strchr(flip, 'y')) skeleton.setScaleY(-1);
    printf("{\"version\":");
    printString(data->getVersion());
    putchar(',');
    printNames("bones", skeleton.getBones());
    putchar(',');
    printNames("slots", skeleton.getSlots());
    putchar(',');
    printNames("skins", data->getSkins());
    printf("}\n");

    Vector<float> buffer;
    Vector<Event *> events;
    Vector<Skin *> &skins = data->getSkins();
    Vector<Animation *> &animations = data->getAnimations();
    const String none;
    for (size_t s = 0; s == 0 || s < skins.size(); s++) {
        Skin *skin = s < skins.size() ? skins[s] : nullptr;
        const String &skinName = skin ? skin->getName() : none;
        skeleton.setSkin(skin);
        skeleton.setToSetupPose();
        updateWorldTransform(skeleton, -1);
        printSample(skeleton, skinName, none, 0, nullptr, buffer);

        for (size_t a = 0; a < animations.size(); a++) {
            Animation &animation = *animations[a];
            float duration = animation.getDuration();
            // half frames avoid stepped keys on sample times
            for (int frame = -1; frame < 0 || (frame + 0.5f) / sample_rate < duration; frame++) {
                float time = frame < 0 ? 0 : (frame + 0.5f) / sample_rate;
                float delta = frame < 0 ? -1 : frame == 0 ? time : 1 / sample_rate;
                events.clear();
                if (frame < 0) {
                    animation.apply(
                        skeleton,
                        -1,
                        duration,
                        false,
                        &events,
                        1,
                        MixBlend_Setup,
                        MixDirection_In
                    );
                }
                skeleton.setToSetupPose();
                animation.apply(
                    skeleton,
                    time,
                    time,
                    false,
                    nullptr,
                    1,
                    MixBlend_Setup,
                    MixDirection_In
                );
                updateWorldTransform(skeleton, delta);
                printSample(
                    skeleton,
                    skinName,
                    animation.getName(),
                    time,
                    frame < 0 ? &events : nullptr,
                    buffer
                );
            }
        }
    }

    delete data;
    return 0;
}
