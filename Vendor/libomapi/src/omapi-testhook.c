/*
 * PATCH (omgui-mac): test hooks for the download-thread liveness protocol.  Not upstream.
 *
 * The H1-H4 shutdown/removal redesign (Vendor/PATCHES.md) turns on one contract: a download thread
 * publishes `downloadFinished` as the last thing it does with its OmDeviceState, and nothing frees
 * that state or destroys a mutex the thread can take until it has.  Everything else in the redesign
 * -- the IOKit removal callback that must not join, the bounded join in OmShutdown(), the leak on
 * timeout -- is a consequence of that contract, and it is the one part of the redesign that can be
 * exercised with no AX3/AX6 attached.
 *
 * It cannot be reached through the public API: OmBeginDownloading() needs a started library, a
 * discovered device, and a seekable file, so it can only ever be given a source that reads to
 * completion in microseconds.  These hooks stand a real OmDeviceState up over a caller-supplied
 * file descriptor -- a pipe, so the test decides exactly when a read completes and when it blocks
 * forever -- and then run the real OmDownloadThread() over it through the same
 * OmDownloadStartThread() the download path uses.  The test drives OmDownloadRequestCancel() and
 * OmDownloadJoinBounded() directly: the same functions the removal callback and OmShutdown() call.
 *
 * Nothing in Sources/ calls any of this.  See Tests/OmApiTests/LibOmapiDownloadProtocolTests.swift.
 */

#include "omapi-internal.h"


/** Records created by OmTestDeviceCreate(), so OmTestEnd() can take them back out of om. */
static OmDeviceRecord *gTestRecords[8];
static int gTestRecordCount;


int OmTestBegin(void)
{
    if (om.initialized) { return OM_E_NOT_VALID_STATE; }

    gTestRecordCount = 0;
    om.apiVersion = OM_VERSION;

    /* The same mutex setup OmStartup() performs, without OmDeviceDiscoveryStart(): these tests are
       about the download threads, and starting IOKit discovery in a unit test would make them
       depend on what is plugged into the machine. */
    mutex_init(&om.portMutex, NULL);
#if !defined(_WIN32)
    {
        pthread_mutexattr_t attr;
        pthread_mutexattr_init(&attr);
        pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
        mutex_init(&om.downloadMutex, &attr);
    }
#else
    mutex_init(&om.downloadMutex, NULL);
#endif

    om.initialized = 1;
    return OM_OK;
}


void OmTestEnd(void)
{
    int i;
    int leaked = 0;

    if (!om.initialized) { return; }
    om.initialized = 0;

    /* Exactly OmShutdown()'s shape: request cancellation for everything first, then reap with one
       shared budget, and leave the mutexes alone if any thread missed it. */
    for (i = 0; i < gTestRecordCount; i++)
    {
        if (gTestRecords[i]->state != NULL) { OmDownloadRequestCancel(gTestRecords[i]->state); }
    }
    for (i = 0; i < gTestRecordCount; i++)
    {
        OmDeviceState *state = gTestRecords[i]->state;
        if (state == NULL) { continue; }
        if (!OmDownloadJoinBounded(state, OM_DOWNLOAD_JOIN_TIMEOUT_MS)) { leaked = 1; continue; }
        gTestRecords[i]->state = NULL;
        free(state);
    }

    /* Unlink every record this file added, so a later test sees the table it expects. */
    for (i = 0; i < gTestRecordCount; i++)
    {
        OmDeviceRecord **link;
        for (link = (OmDeviceRecord **)&om.deviceRecords; *link != NULL; link = &(*link)->next)
        {
            if (*link == gTestRecords[i]) { *link = gTestRecords[i]->next; break; }
        }
        free(gTestRecords[i]);
        gTestRecords[i] = NULL;
    }
    gTestRecordCount = 0;

    if (leaked) { return; }
    mutex_destroy(&om.portMutex);
    mutex_destroy(&om.downloadMutex);
}


OmDeviceState *OmTestDeviceCreate(unsigned int deviceId, int sourceFd, const char *destPath, int blocksTotal)
{
    OmDeviceState *state;
    OmDeviceRecord *record;

    if (!om.initialized) { return NULL; }
    if (gTestRecordCount >= (int)(sizeof(gTestRecords) / sizeof(gTestRecords[0]))) { return NULL; }

    state = (OmDeviceState *)malloc(sizeof(OmDeviceState));
    if (state == NULL) { return NULL; }
    memset(state, 0, sizeof(OmDeviceState));
    state->id = deviceId;
    state->fd = -1;
    state->deviceStatus = OM_DEVICE_CONNECTED;
    state->downloadBlocksTotal = blocksTotal;

    state->downloadSource = fdopen(sourceFd, "rb");
    if (state->downloadSource == NULL) { free(state); return NULL; }
    if (destPath != NULL)
    {
        state->downloadDest = fopen(destPath, "wb");
        if (state->downloadDest == NULL) { fclose(state->downloadSource); free(state); return NULL; }
    }

    record = (OmDeviceRecord *)malloc(sizeof(OmDeviceRecord));
    if (record == NULL)
    {
        fclose(state->downloadSource);
        if (state->downloadDest != NULL) { fclose(state->downloadDest); }
        free(state);
        return NULL;
    }
    memset(record, 0, sizeof(OmDeviceRecord));
    record->id = deviceId;
    record->state = state;
    record->next = om.deviceRecords;
    om.deviceRecords = record;
    gTestRecords[gTestRecordCount++] = record;

    return state;
}


int OmTestDownloadStart(OmDeviceState *device)
{
    return OmDownloadStartThread(device);
}


int OmTestDownloadFinished(OmDeviceState *device)
{
    return (device != NULL && device->downloadFinished) ? 1 : 0;
}


int OmTestDownloadStreamsClosed(OmDeviceState *device)
{
    int closed;
    unsigned int deviceId;
    if (device == NULL) { return 1; }
    deviceId = device->id;
    (void)deviceId;             // referenced by the Win32 OM_DEBUG_MUTEX form of mutex_lock()
    mutex_lock(&om.downloadMutex);
    closed = (device->downloadSource == NULL && device->downloadDest == NULL) ? 1 : 0;
    mutex_unlock(&om.downloadMutex);
    return closed;
}


int OmTestDownloadStatus(OmDeviceState *device)
{
    OM_DOWNLOAD_STATUS status;
    unsigned int deviceId;
    if (device == NULL) { return OM_DOWNLOAD_NONE; }
    deviceId = device->id;
    (void)deviceId;             // referenced by the Win32 OM_DEBUG_MUTEX form of mutex_lock()
    mutex_lock(&om.downloadMutex);
    status = device->downloadStatus;
    mutex_unlock(&om.downloadMutex);
    return (int)status;
}


int OmTestDownloadThreadActive(OmDeviceState *device)
{
    return (device != NULL && device->downloadThreadActive) ? 1 : 0;
}
