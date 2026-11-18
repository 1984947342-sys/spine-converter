// Pose dumper for the 3.5 and 3.6 spine-c runtimes, SPINE_VERSION is major * 100 + minor
// Output matches dump.cpp
#include <spine/spine.h>
#include <spine/extension.h>

#include <locale.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const float sample_rate = 30;

static float *buffer;
static int capacity;

static float *reserve(int count) {
    if (count > capacity) {
        capacity = count;
        buffer = realloc(buffer, capacity * sizeof(float));
    }
    return buffer;
}

void _spAtlasPage_createTexture(spAtlasPage *self, const char *path) {
    (void)self;
    (void)path;
}

void _spAtlasPage_disposeTexture(spAtlasPage *self) {
    (void)self;
}

char *_spUtil_readFile(const char *path, int *length) {
    FILE *file = fopen(path, "rb");
    if (!file) return NULL;
    fseek(file, 0, SEEK_END);
    long size = ftell(file);
    fseek(file, 0, SEEK_SET);
    char *data = malloc(size + 1);
    *length = (int)fread(data, 1, size, file);
    data[*length] = 0;
    fclose(file);
    return data;
}

static void printFloat(float value) {
    if (isfinite(value))
        printf("%.9g", value);
    else
        printf("null");
}

static void printString(const char *value) {
    putchar('"');
    for (const char *c = value; c && *c; c++) {
        if (*c == '"' || *c == '\\')
            printf("\\%c", *c);
        else if ((unsigned char)*c < 0x20)
            printf("\\u%04x", *c);
        else
            putchar(*c);
    }
    putchar('"');
}

static void printColor(float r, float g, float b, float a) {
    putchar('[');
    printFloat(r);
    putchar(',');
    printFloat(g);
    putchar(',');
    printFloat(b);
    if (a >= 0) {
        putchar(',');
        printFloat(a);
    }
    putchar(']');
}

static void printVertices(spSlot *slot) {
    spAttachment *attachment = slot->attachment;
    int count = 0;
    if (attachment && attachment->type == SP_ATTACHMENT_REGION) {
        count = 8;
        reserve(count);
#if SPINE_VERSION >= 306
        spRegionAttachment_computeWorldVertices((spRegionAttachment *)attachment, slot->bone, buffer, 0, 2);
#else
        spRegionAttachment_computeWorldVertices((spRegionAttachment *)attachment, slot->bone, buffer);
        // 3.6 starts at the bottom right corner
        float br[2] = {buffer[6], buffer[7]};
        memmove(buffer + 2, buffer, 6 * sizeof(float));
        buffer[0] = br[0];
        buffer[1] = br[1];
#endif
    } else if (attachment && attachment->type != SP_ATTACHMENT_REGION
#if SPINE_VERSION >= 306
               && attachment->type != SP_ATTACHMENT_POINT
#endif
    ) {
        spVertexAttachment *vertices = (spVertexAttachment *)attachment;
        count = vertices->worldVerticesLength;
        reserve(count);
#if SPINE_VERSION >= 306
        spVertexAttachment_computeWorldVertices(vertices, slot, 0, count, buffer, 0, 2);
#else
        spVertexAttachment_computeWorldVertices(vertices, slot, buffer);
#endif
    }
    putchar('[');
    for (int i = 0; i < count; i++) {
        if (i) putchar(',');
        printFloat(buffer[i]);
    }
    putchar(']');
}

static const int clip_cells = 4;

/** Covered fraction of each cell of a grid over the clipping polygon bounds */
static void printClip(spSlot *slot) {
#if SPINE_VERSION >= 306
    spAttachment *attachment = slot->attachment;
    if (!attachment || attachment->type != SP_ATTACHMENT_CLIPPING) {
        printf("null");
        return;
    }
    spClippingAttachment *clip = (spClippingAttachment *)attachment;
    int n = clip->super.worldVerticesLength;
    float *world = reserve(n);
    spVertexAttachment_computeWorldVertices(&clip->super, slot, 0, n, world, 0, 2);
    float minX = world[0], minY = world[1], maxX = world[0], maxY = world[1];
    for (int i = 2; i < n; i += 2) {
        minX = fminf(minX, world[i]);
        maxX = fmaxf(maxX, world[i]);
        minY = fminf(minY, world[i + 1]);
        maxY = fmaxf(maxY, world[i + 1]);
    }
    spSkeletonClipping *clipper = spSkeletonClipping_create();
    if (spSkeletonClipping_clipStart(clipper, slot, clip) == 0) {
        printf("[]");
        spSkeletonClipping_dispose(clipper);
        return;
    }
    float w = (maxX - minX) / clip_cells, h = (maxY - minY) / clip_cells;
    unsigned short triangles[] = {0, 1, 2, 0, 2, 3};
    putchar('[');
    for (int cell = 0; cell < clip_cells * clip_cells; cell++) {
        float x = minX + w * (cell % clip_cells), y = minY + h * (cell / clip_cells);
        float quad[] = {x, y, x + w, y, x + w, y + h, x, y + h};
        float uvs[8] = {0};
        spSkeletonClipping_clipTriangles(clipper, quad, 8, triangles, 6, uvs, 2);
        float *v = clipper->clippedVertices->items;
        unsigned short *t = clipper->clippedTriangles->items;
        float area = 0;
        for (int i = 0; i < clipper->clippedTriangles->size; i += 3) {
            float ax = v[t[i] * 2], ay = v[t[i] * 2 + 1];
            float bx = v[t[i + 1] * 2], by = v[t[i + 1] * 2 + 1];
            float cx = v[t[i + 2] * 2], cy = v[t[i + 2] * 2 + 1];
            area += fabsf((bx - ax) * (cy - ay) - (cx - ax) * (by - ay)) / 2;
        }
        if (cell) putchar(',');
        printFloat(w * h > 0 ? area / (w * h) : 0);
    }
    putchar(']');
    spSkeletonClipping_clipEnd2(clipper);
    spSkeletonClipping_dispose(clipper);
#else
    (void)slot;
    printf("null");
#endif
}

/** Audio events start with 3.7, older events print the 3.7 defaults */
static void printEvents(spEvent **events, int count) {
    printf(",\"events\":[");
    for (int i = 0; i < count; i++) {
        spEvent *event = events[i];
        if (i) putchar(',');
        putchar('[');
        printString(event->data->name);
        printf(",%d,", event->intValue);
        printFloat(event->floatValue);
        putchar(',');
        printString(event->stringValue);
        printf(",1,0,");
        printFloat(event->time);
        printf(",\"\"]");
    }
    putchar(']');
}

static void printSample(
    spSkeleton *skeleton,
    const char *skin,
    const char *animation,
    float time,
    spEvent **events,
    int eventCount
) {
    printf("{\"skin\":");
    printString(skin);
    printf(",\"animation\":");
    printString(animation);
    printf(",\"time\":");
    printFloat(time);
    if (events) printEvents(events, eventCount);

    printf(",\"bones\":[");
    for (int i = 0; i < skeleton->bonesCount; i++) {
        spBone *bone = skeleton->bones[i];
        if (i) putchar(',');
        float values[] = {bone->a, bone->b, bone->c, bone->d, bone->worldX, bone->worldY};
        putchar('[');
        for (int v = 0; v < 6; v++) {
            if (v) putchar(',');
            printFloat(values[v]);
        }
        putchar(']');
    }

    printf("],\"slots\":[");
    for (int i = 0; i < skeleton->slotsCount; i++) {
        spSlot *slot = skeleton->slots[i];
        if (i) putchar(',');
        printf("{\"attachment\":");
        if (slot->attachment)
            printString(slot->attachment->name);
        else
            printf("null");
        printf(",\"color\":");
#if SPINE_VERSION >= 306
        printColor(slot->color.r, slot->color.g, slot->color.b, slot->color.a);
        printf(",\"dark\":");
        if (slot->darkColor)
            printColor(slot->darkColor->r, slot->darkColor->g, slot->darkColor->b, -1);
        else
            printf("null");
#else
        printColor(slot->r, slot->g, slot->b, slot->a);
        printf(",\"dark\":null");
#endif
        printf(",\"vertices\":");
        printVertices(slot);
        printf(",\"clip\":");
        printClip(slot);
        putchar('}');
    }

    printf("],\"drawOrder\":[");
    for (int i = 0; i < skeleton->slotsCount; i++) {
        if (i) putchar(',');
        printf("%d", skeleton->drawOrder[i]->data->index);
    }
    printf("]}\n");
}

static int printAtlas(spAtlas *atlas) {
    if (!atlas || !atlas->pages) {
        fprintf(stderr, "atlas has no pages\n");
        return 1;
    }
    for (spAtlasPage *page = atlas->pages; page; page = page->next) {
        printf("page\t");
        printString(page->name);
        // spine-cpp numbers formats from Alpha
        printf(
            "\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t0\n",
            page->width,
            page->height,
            (int)page->format - 1,
            (int)page->minFilter,
            (int)page->magFilter,
            (int)page->uWrap,
            (int)page->vWrap
        );
    }
    for (spAtlasRegion *region = atlas->regions; region; region = region->next) {
        int p = 0;
        for (spAtlasPage *page = atlas->pages; page != region->page; page = page->next) p++;
        printf("region\t%d\t", p);
        printString(region->name);
        printf("\t%d\t%d\t%d\t%d", region->x, region->y, region->width, region->height);
        float floats[] = {
            region->u,
            region->v,
            region->u2,
            region->v2,
            (float)region->offsetX,
            (float)region->offsetY
        };
        for (int f = 0; f < 6; f++) {
            putchar('\t');
            printFloat(floats[f]);
        }
        printf(
            "\t%d\t%d\t%d\t%d\t",
            region->originalWidth,
            region->originalHeight,
            region->rotate ? 90 : 0,
            region->index
        );
        // 4.x keeps split and pad as named values
        printf("%s\t", region->splits ? (region->pads ? "split,pad" : "split") : "");
        for (int v = 0; v < (region->splits ? 4 : 0) + (region->pads ? 4 : 0); v++) {
            if (v) putchar(',');
            printf("%d", v < 4 && region->splits ? region->splits[v] : region->pads[v - 4]);
        }
        putchar('\n');
    }
    return 0;
}

/** Event pointers one animation can fire */
static int eventCapacity(spAnimation *animation) {
    int capacity = 0;
    for (int i = 0; i < animation->timelinesCount; i++) {
        spTimeline *timeline = animation->timelines[i];
        if (timeline->type == SP_TIMELINE_EVENT) capacity += ((spEventTimeline *)timeline)->framesCount;
    }
    return capacity;
}

static void apply(spAnimation *animation, spSkeleton *skeleton, float lastTime, float time, spEvent **events, int *count) {
#if SPINE_VERSION >= 306
    spAnimation_apply(animation, skeleton, lastTime, time, 0, events, count, 1, SP_MIX_POSE_SETUP, SP_MIX_DIRECTION_IN);
#else
    spAnimation_apply(animation, skeleton, lastTime, time, 0, events, count, 1, 1, 0);
#endif
}

int main(int argc, char **argv) {
    setlocale(LC_ALL, "C");
    if (argc == 2) {
        spAtlas *atlas = spAtlas_createFromFile(argv[1], NULL);
        return printAtlas(atlas);
    }
    if (argc != 3) {
        fprintf(stderr, "usage: %s <skeleton.json|skeleton.skel> <atlas>\n", argv[0]);
        fprintf(stderr, "       %s <atlas>\n", argv[0]);
        return 2;
    }
    spBone_setYDown(0);

    spAtlas *atlas = spAtlas_createFromFile(argv[2], NULL);
    if (!atlas) {
        fprintf(stderr, "cannot read atlas %s\n", argv[2]);
        return 1;
    }
    spSkeletonData *data;
    const char *error;
    if (strstr(argv[1], ".json")) {
        spSkeletonJson *json = spSkeletonJson_create(atlas);
        data = spSkeletonJson_readSkeletonDataFile(json, argv[1]);
        error = json->error;
    } else {
        spSkeletonBinary *binary = spSkeletonBinary_create(atlas);
        data = spSkeletonBinary_readSkeletonDataFile(binary, argv[1]);
        error = binary->error;
    }
    if (!data) {
        fprintf(stderr, "%s\n", error ? error : "cannot read skeleton");
        return 1;
    }

    spSkeleton *skeleton = spSkeleton_create(data);
    const char *flip = getenv("ORACLE_FLIP");
    if (flip && strchr(flip, 'x')) skeleton->flipX = 1;
    if (flip && strchr(flip, 'y')) skeleton->flipY = 1;
    printf("{\"version\":");
    printString(data->version);
    printf(",\"bones\":[");
    for (int i = 0; i < skeleton->bonesCount; i++) {
        if (i) putchar(',');
        printString(skeleton->bones[i]->data->name);
    }
    printf("],\"slots\":[");
    for (int i = 0; i < skeleton->slotsCount; i++) {
        if (i) putchar(',');
        printString(skeleton->slots[i]->data->name);
    }
    printf("],\"skins\":[");
    for (int i = 0; i < data->skinsCount; i++) {
        if (i) putchar(',');
        printString(data->skins[i]->name);
    }
    printf("]}\n");

    for (int s = 0; s == 0 || s < data->skinsCount; s++) {
        spSkin *skin = s < data->skinsCount ? data->skins[s] : NULL;
        const char *skinName = skin ? skin->name : "";
        spSkeleton_setSkin(skeleton, skin);
        spSkeleton_setToSetupPose(skeleton);
        spSkeleton_updateWorldTransform(skeleton);
        printSample(skeleton, skinName, "", 0, NULL, 0);

        for (int a = 0; a < data->animationsCount; a++) {
            spAnimation *animation = data->animations[a];
            float duration = animation->duration;
            spEvent **events = malloc((eventCapacity(animation) + 1) * sizeof(spEvent *));
            // half frames avoid stepped keys on sample times
            for (int frame = -1; frame < 0 || (frame + 0.5f) / sample_rate < duration; frame++) {
                float time = frame < 0 ? 0 : (frame + 0.5f) / sample_rate;
                int count = 0;
                if (frame < 0) apply(animation, skeleton, -1, duration, events, &count);
                spSkeleton_setToSetupPose(skeleton);
                apply(animation, skeleton, time, time, NULL, NULL);
                spSkeleton_updateWorldTransform(skeleton);
                printSample(skeleton, skinName, animation->name, time, frame < 0 ? events : NULL, count);
            }
            free(events);
        }
    }
    spSkeleton_dispose(skeleton);
    spSkeletonData_dispose(data);
    return 0;
}
