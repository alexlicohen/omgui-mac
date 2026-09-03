/* 
 * Copyright (c) 2009-2012, Newcastle University, UK.
 * All rights reserved.
 * 
 * Redistribution and use in source and binary forms, with or without 
 * modification, are permitted provided that the following conditions are met: 
 * 1. Redistributions of source code must retain the above copyright notice, 
 *    this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright notice, 
 *    this list of conditions and the following disclaimer in the documentation 
 *    and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" 
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE 
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE 
 * ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE 
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR 
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF 
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS 
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN 
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) 
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE 
 * POSSIBILITY OF SUCH DAMAGE. 
 */

// Open Movement API - Download Functions
// Dan Jackson, 2011-2012

#include "omapi-internal.h"
#include <sys/stat.h>
#if !defined(_WIN32)
#include <sys/time.h>       /* PATCH (omgui-mac) H3: gettimeofday() for the bounded join */
#endif


/** Download buffer size */
#define OM_DOWNLOAD_BLOCK_SET (256)


/* PATCH (omgui-mac) H1/H3: the download-thread liveness protocol.
 *
 * A separate mutex and condition variable, statically initialised and never destroyed.  Separate
 * because om.downloadMutex is PTHREAD_MUTEX_RECURSIVE and waiting on a condition variable with a
 * recursive mutex is undefined; statically initialised and never destroyed because the whole point
 * of the protocol is to survive a shutdown that has given up on a thread -- an orphan must still be
 * able to publish that it has let go of its OmDeviceState, and a mutex destroyed under it would be
 * the very use-after-free this replaces.  It is one condition variable for all devices: waiters
 * re-check their own device's downloadFinished flag.
 */
#if !defined(_WIN32)
static pthread_mutex_t gDownloadDoneMutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t gDownloadDoneCond = PTHREAD_COND_INITIALIZER;
#endif


/** Publish that the download thread has stopped touching this OmDeviceState. */
static void OmDownloadPublishFinished(OmDeviceState *device)
{
#if !defined(_WIN32)
    pthread_mutex_lock(&gDownloadDoneMutex);
    device->downloadFinished = 1;
    pthread_cond_broadcast(&gDownloadDoneCond);
    pthread_mutex_unlock(&gDownloadDoneMutex);
#else
    device->downloadFinished = 1;
#endif
}


/** Internal method to update the download progress. */
static int OmDoDownloadUpdate(unsigned int deviceId, OM_DOWNLOAD_STATUS downloadStatus, int downloadValue)
{
    // Check system and device state
    if (!om.initialized) return OM_E_NOT_VALID_STATE;
	OmDeviceState *device = OmDevice(deviceId);
    if (device == NULL) return OM_E_INVALID_DEVICE;   // Device never seen

    // Acquire download mutex here (otherwise there is a small window here in which the state will become unknown if accessed from another thread)
    mutex_lock(&om.downloadMutex);          // Lock download mutex to update device state structure
    device->downloadStatus = downloadStatus;
    device->downloadValue = downloadValue;
    mutex_unlock(&om.downloadMutex);        // Release download mutex after updating device state structure

    // Call user-supplied callback
    if (om.downloadCallback != NULL)
    {
        om.downloadCallback(device->downloadReference != NULL ? device->downloadReference : om.downloadCallbackReference, deviceId, device->downloadStatus, device->downloadValue);
    }

    return OM_OK;
}


/** Internal method to run the download thread. */
static thread_return_t OmDownloadThread(void *arg)
{
    int downloadValue = OM_E_UNEXPECTED;
    OM_DOWNLOAD_STATUS downloadStatus = OM_DOWNLOAD_ERROR;
    OmDeviceState *deviceState = (OmDeviceState *)arg;
    char *buffer = (char *)malloc((OM_DOWNLOAD_BLOCK_SET * OM_BLOCK_SIZE));
    if (buffer == NULL)
    { 
        downloadStatus = (OM_DOWNLOAD_STATUS)OM_E_OUT_OF_MEMORY; 
    }
    else if (deviceState->downloadSource == NULL)
    {
        downloadStatus = (OM_DOWNLOAD_STATUS)OM_E_POINTER; 
    }
    else
    {
		int lastDownloadValue;

        // Initial status update
        downloadStatus = OM_DOWNLOAD_PROGRESS;
        downloadValue = 0;
        OmDoDownloadUpdate(deviceState->id, downloadStatus, downloadValue);
		lastDownloadValue = downloadValue;

        // Copy loop
        while (downloadStatus == OM_DOWNLOAD_PROGRESS)
        {
            int blocksRead, blocksWritten;
            int position;
            int toRead;

            // Calculate how many blocks to read
            toRead = deviceState->downloadBlocksTotal - deviceState->downloadBlocksCopied;
            if (toRead > OM_DOWNLOAD_BLOCK_SET) { toRead = OM_DOWNLOAD_BLOCK_SET; }
            if (toRead <= 0) { downloadValue = 100; downloadStatus = OM_DOWNLOAD_COMPLETE; break; }

            // Check for cancellation
            if (deviceState->downloadCancel) { downloadStatus = OM_DOWNLOAD_CANCELLED; break; }

            // Check for unexpected end
            if (feof(deviceState->downloadSource)) { downloadStatus = OM_DOWNLOAD_ERROR; break; }

            // Get current position
            position = ftell(deviceState->downloadSource);

            // Read a block of data
            blocksRead = (int)fread(buffer, OM_BLOCK_SIZE, toRead, deviceState->downloadSource);
            if (blocksRead <= 0) { downloadStatus = OM_DOWNLOAD_ERROR; downloadValue = OM_E_ACCESS_DENIED; break; }

            // Check for cancellation
            if (deviceState->downloadCancel) { downloadStatus = OM_DOWNLOAD_CANCELLED; break; }

            // Call user-supplied chunk callback
            if (om.downloadChunkCallback != NULL)
            {
                om.downloadChunkCallback(deviceState->downloadReference != NULL ? deviceState->downloadReference : om.downloadChunkCallbackReference, deviceState->id, buffer, position, blocksRead * OM_BLOCK_SIZE);
            }

            // Write the block of data
            if (deviceState->downloadDest == NULL)
            {
                blocksWritten = blocksRead;
            }
            else
            {
                blocksWritten = (int)fwrite(buffer, OM_BLOCK_SIZE, blocksRead, deviceState->downloadDest);
                if (blocksWritten != blocksRead) {  downloadStatus = OM_DOWNLOAD_ERROR; downloadValue = OM_E_ACCESS_DENIED; break; }
            }

            // Update progress
            deviceState->downloadBlocksCopied += blocksWritten;
            if (deviceState->downloadBlocksTotal == 0) { downloadValue = 0; }
            else { downloadValue = (int)(deviceState->downloadBlocksCopied * 100UL / deviceState->downloadBlocksTotal); }
			if (downloadValue != lastDownloadValue)
			{
				OmDoDownloadUpdate(deviceState->id, downloadStatus, downloadValue);
				lastDownloadValue = downloadValue;
			}
        }
    }

    // Close resources
    //
    // PATCH (omgui-mac) H1/H3: the streams are closed and cleared under om.downloadMutex, and
    // OmDownloadRequestCancel() invalidates the source descriptor under the same mutex.  That
    // pairing is what makes the cancel safe: while the canceller holds the mutex the FILE* it read
    // cannot be closed underneath it, and while this epilogue holds it no cancel can be looking at
    // a stream that is being torn down.  Clearing the pointers also removes the double fclose()
    // that a second cancel used to cause.
    if (buffer != NULL) { free(buffer); }
    mutex_lock(&om.downloadMutex);
    if (deviceState->downloadSource != NULL) { fclose(deviceState->downloadSource); deviceState->downloadSource = NULL; }
    if (deviceState->downloadDest != NULL) { fclose(deviceState->downloadDest); deviceState->downloadDest = NULL; }
    mutex_unlock(&om.downloadMutex);

    // Update progress
    OmDoDownloadUpdate(deviceState->id, downloadStatus, downloadValue);

    // PATCH (omgui-mac) H3: the last thing this thread does with `deviceState`.  A shutdown that
    // has seen this flag may free the state immediately; nothing below may touch it again.
    OmDownloadPublishFinished(deviceState);

    // Return
    return thread_return_value(0);
}


int OmGetDataFileSize(int deviceId)
{
    int status;
    char filename[OM_MAX_PATH];
    struct stat s;

    status = OmGetDataFilename(deviceId, filename);
    if (OM_FAILED(status)) { return status; }

    if (stat(filename, &s) != 0) { return OM_E_ACCESS_DENIED; }

    return (int)s.st_size;
}


int OmGetDataFilename(int deviceId, char *filenameBuffer)
{
	int retVal;
	int written;
	char path[OM_MAX_PATH];

	// PATCH (omgui-mac) C13: upstream strcat()'d "/CWA-DATA.CWA" (13 bytes) straight onto the
	// device path.  OmGetDevicePath() fills its buffer from OmDeviceState.root, which holds up to
	// OM_MAX_PATH-1 characters, so the concatenation overran the OM_MAX_PATH buffer omapi.h
	// documents for this parameter -- and every internal caller here declares exactly that.  The
	// path is now built with a bounded snprintf() into a private buffer and copied back only if
	// it fits; an over-long volume path is an error rather than a stack smash.  The signature is
	// deliberately unchanged (the Swift seam passes a larger buffer, which stays valid).
	if (filenameBuffer == NULL) { return OM_E_POINTER; }
	filenameBuffer[0] = '\0';

	retVal = OmGetDevicePath(deviceId, path);
	if (retVal != OM_OK)
	{
		return retVal;
	}

#if defined(_WIN32)
	written = snprintf(filenameBuffer, OM_MAX_PATH, "%s%s", path, OM_DEFAULT_FILENAME);
#else
	written = snprintf(filenameBuffer, OM_MAX_PATH, "%s/%s", path, OM_DEFAULT_FILENAME);
#endif
	if (written < 0 || written >= OM_MAX_PATH)
	{
		filenameBuffer[0] = '\0';       // _snprintf() does not terminate a truncated result
		OmLog(0, "ERROR: Data filename for device %d does not fit in OM_MAX_PATH.\n", deviceId);
		return OM_E_FAIL;
	}

    // Check file existence/properties
#if 0
    {
        struct stat s;
        int result;
        result = stat(filenameBuffer, &s);
        if (result != 0)
        {
            return OM_E_ACCESS_DENIED;
        }
        //buf.st_size       // file size
        //buf.st_mtime
    }
#endif

    return OM_OK;
}


int OmGetDataRange(int deviceId, int *dataBlockSize, int *dataOffsetBlocks, int *dataNumBlocks, OM_DATETIME *startTime, OM_DATETIME *endTime)
{
    int status;
    char filename[OM_MAX_PATH];
    OmReaderHandle reader;

    status = OmGetDataFilename(deviceId, filename);
    if (OM_FAILED(status)) { return status; }

    reader = OmReaderOpen(filename);
    if (reader == NULL) { return OM_E_ACCESS_DENIED; }

    status = OmReaderDataRange(reader, dataBlockSize, dataOffsetBlocks, dataNumBlocks, startTime, endTime);

    OmReaderClose(reader);

    return status;
}


int OmBeginDownloading(int deviceId, int dataOffsetBlocks, int dataLengthBlocks, const char *destinationFile)
{
    return OmBeginDownloadingReference(deviceId, dataOffsetBlocks, dataLengthBlocks, destinationFile, NULL);
}


int OmBeginDownloadingReference(int deviceId, int dataOffsetBlocks, int dataLengthBlocks, const char *destinationFile, void *reference)
{
    int status;
    char filename[OM_MAX_PATH];
 
    // Check system and device state
    if (!om.initialized) return OM_E_NOT_VALID_STATE;
	OmDeviceState *device = OmDevice(deviceId);
	if (device == NULL) return OM_E_INVALID_DEVICE;   // Device never seen
    if (device->deviceStatus != OM_DEVICE_CONNECTED) return OM_E_INVALID_DEVICE;   // Device lost

    // Check parameters
    if (dataOffsetBlocks < 0) return OM_E_INVALID_ARG;
    if (dataLengthBlocks < -1) return OM_E_INVALID_ARG;
    if (destinationFile != NULL && !strlen(destinationFile)) return OM_E_INVALID_ARG;

    // Acquire download mutex here (otherwise there is a small window here in which the state will become unknown if two threads start a download at exactly the same time).
    mutex_lock(&om.downloadMutex);          // Lock download mutex to begin download thread
    do          // This is only a 'do' to allow a single code path to hit the mutex unlock with any exceptional 'break's
    {
        int fileTotalBlocks;

        // Checks if we are already downloading, fails if a download is in progress
        if (device->downloadStatus == OM_DOWNLOAD_PROGRESS) { status = OM_E_NOT_VALID_STATE; break; }

        // PATCH (omgui-mac) H1: reap the previous download thread here rather than overwriting --
        // and permanently leaking -- its handle.  A download cancelled by a hot-unplug is
        // deliberately not joined on the IOKit run-loop thread (see OmDownloadRequestCancel), so
        // this is where that thread is collected; it has already published downloadFinished, so
        // the join returns at once.  A thread that has *not* finished means the caller is racing
        // its own download, which is refused rather than started twice.
        if (device->downloadThreadActive)
        {
            if (!device->downloadFinished) { status = OM_E_NOT_VALID_STATE; break; }
            if (device->downloadThread) { thread_join(device->downloadThread, NULL); }
            device->downloadThread = 0;
            device->downloadThreadActive = 0;
        }

        // Sets the download status to not-started
        device->downloadStatus = OM_DOWNLOAD_NONE;

        // Checks system and device state and gets the data file name for the specified device
        status = OmGetDataFilename(deviceId, filename);
        if (OM_FAILED(status)) { break; }

        // Open the source file
        device->downloadSource = fopen(filename, "rb");
        if (device->downloadSource == NULL) { status = OM_E_ACCESS_DENIED; break; }

        // Open the destination file
        if (destinationFile == NULL)
        {
            device->downloadDest = NULL;
        }
        else
        {
            device->downloadDest = fopen(destinationFile, "wb");
            if (device->downloadDest == NULL) { fclose(device->downloadSource); device->downloadSource = NULL; status = OM_E_ACCESS_DENIED; break; }
        }

        // Calculate the total number of blocks in the file
        fseek(device->downloadSource, 0, SEEK_END);
        fileTotalBlocks = ftell(device->downloadSource) / OM_BLOCK_SIZE;

        // Seek to the requested block offset
        if (dataOffsetBlocks > fileTotalBlocks) { fclose(device->downloadSource); device->downloadSource = NULL; status = OM_E_INVALID_ARG; break; }
        fseek(device->downloadSource, OM_BLOCK_SIZE * dataOffsetBlocks, SEEK_SET);

        // If the requested total number of blocks is negative, use the actual number remaining
        if (dataLengthBlocks < 0)
        {
            device->downloadBlocksTotal = fileTotalBlocks - dataOffsetBlocks;
        }
        else
        {
            device->downloadBlocksTotal = fileTotalBlocks;
        }

        // If the requested number of blocks is too many, return
        if (dataOffsetBlocks + device->downloadBlocksTotal > fileTotalBlocks) { fclose(device->downloadSource); device->downloadSource = NULL; status = OM_E_INVALID_ARG; break; }

        // Start the download thread
        device->downloadReference = reference;
        //OmDoDownloadUpdate(device->id, OM_DOWNLOAD_PROGRESS, 0);        // Removed - don't do an initial update here, one is done in OmDownloadThread anyway, and don't want to call out to user code with the download mutex held
        status = OmDownloadStartThread(device);     // PATCH (omgui-mac) H1/H3
        if (OM_FAILED(status))
        {
            fclose(device->downloadSource); device->downloadSource = NULL;
            if (device->downloadDest != NULL) { fclose(device->downloadDest); device->downloadDest = NULL; }
            break;
        }
    } while(0);
    mutex_unlock(&om.downloadMutex);        // Release download mutex after updating beginning download thread

    return status;
}


/** PATCH (omgui-mac) H1/H3: the one place a download thread is created and its liveness protocol
 *  armed.  `downloadFinished` has to be cleared before the thread exists, or a shutdown racing the
 *  start could read a stale 1 left by the previous download and free the state under the new
 *  thread.  Callers hold om.downloadMutex (it is recursive, so the lock here is free) and own the
 *  source/destination streams on failure. */
int OmDownloadStartThread(OmDeviceState *device)
{
    int status = OM_OK;
    unsigned int deviceId;

    if (device == NULL) { return OM_E_POINTER; }
    deviceId = device->id;
    (void)deviceId;             // referenced by the Win32 OM_DEBUG_MUTEX form of mutex_lock()

    mutex_lock(&om.downloadMutex);
    device->downloadBlocksCopied = 0;
    device->downloadCancel = 0;
    device->downloadFinished = 0;
    if (thread_create(&device->downloadThread, NULL, OmDownloadThread, device) != 0)
    {
        device->downloadThread = 0;
        status = OM_E_UNEXPECTED;
    }
    else
    {
        device->downloadThreadActive = 1;   // There is now a thread that has to be reaped
    }
    mutex_unlock(&om.downloadMutex);
    return status;
}


/** PATCH (omgui-mac) C3: take ownership of the download thread handle, clearing it under the
 *  download mutex so that two threads racing to wait/cancel cannot both join it (joining a
 *  pthread twice is undefined).  Returns 0 if another caller got there first. */
static thread_t OmDownloadTakeThread(OmDeviceState *device, unsigned int deviceId)
{
    thread_t thread;
    (void)deviceId;             // referenced by the Win32 OM_DEBUG_MUTEX form of mutex_lock()
    mutex_lock(&om.downloadMutex);
    thread = device->downloadThread;
    device->downloadThread = 0;
    mutex_unlock(&om.downloadMutex);
    return thread;
}


int OmQueryDownload(int deviceId, OM_DOWNLOAD_STATUS *downloadStatus, int *downloadValue)
{
    OM_DOWNLOAD_STATUS dStatus;
    int value;

    // Check system and device state
    if (!om.initialized) return OM_E_NOT_VALID_STATE;
	OmDeviceState *device = OmDevice(deviceId);
	if (device == NULL) return OM_E_INVALID_DEVICE;   // Device never seen
    if (device->deviceStatus != OM_DEVICE_CONNECTED) return OM_E_INVALID_DEVICE;   // Device lost

    // Acquire download mutex here (otherwise there's a small chance the status and value may be inconsistent and invalidated by a download start/update/stop).
    mutex_lock(&om.downloadMutex);          // Lock download mutex to query device state structure
    {
        dStatus = device->downloadStatus;
        value = device->downloadValue;
    }
    mutex_unlock(&om.downloadMutex);        // Release download mutex after querying device state structure

    // Output values
    if (downloadStatus != NULL) { *downloadStatus = dStatus; }
    if (downloadValue != NULL) { *downloadValue = value; }

    return OM_OK;
}


int OmWaitForDownload(int deviceId, OM_DOWNLOAD_STATUS *downloadStatus, int *downloadValue)
{
    OM_DOWNLOAD_STATUS dStatus = OM_DOWNLOAD_NONE;
    int dValue = -1;
    int status;

    // Check download state
    OmLog(3, "OmWaitForDownload() started.\n");
    status = OmQueryDownload(deviceId, &dStatus, &dValue);
    if (OM_FAILED(status)) { return status; }

    // If downloading...
	OmDeviceState *device = OmDevice(deviceId);
	if (dStatus == OM_DOWNLOAD_PROGRESS && (device->downloadThread))
    {
        // Wait for download thread to terminate
        OmLog(3, "OmWaitForDownload() waiting for download thread to terminate...\n");
        thread_t thread = OmDownloadTakeThread(device, (unsigned int)deviceId);   // PATCH (omgui-mac) C3
        if (thread) { thread_join(thread, NULL); device->downloadThreadActive = 0; }   // PATCH (omgui-mac) H1
    }

    // Check completed download state
    OmLog(3, "OmWaitForDownload() checking status...\n");
    status = OmQueryDownload(deviceId, &dStatus, &dValue);
    if (OM_FAILED(status)) { return status; }

    // Return values
    if (downloadStatus != NULL) { *downloadStatus = dStatus; }
    if (downloadValue != NULL) { *downloadValue = dValue; }

    return OM_OK;
}


/* PATCH (omgui-mac) H2/H3: the second main-thread join, bounded the same way OmShutdown()'s is.
 *
 * Upstream raised downloadCancel outside om.downloadMutex and then called OmWaitForDownload(),
 * whose join has no bound.  That is H3's failure exactly, reached through the Cancel button rather
 * than through Cmd-Q: OmGui calls this from `@MainActor AppModel.cancelDownload()`, and in the
 * window between a device being yanked and IOKit delivering kIOMessageServiceIsTerminated the
 * download thread is parked in fread() on a volume that is no longer there, so the main thread
 * blocked until the kernel timed the read out.  Bounding OmShutdown() alone would have left the
 * same unbounded join one button away.
 *
 * So this runs the same two steps the removal callback and the shutdown run: request cancellation
 * (which raises the flag under om.downloadMutex *and* invalidates the source descriptor, so a
 * blocked read comes back), then reap on a budget.  A thread that misses the budget is detached
 * rather than waited on; its state stays alive and downloadThreadActive stays up, so the next
 * OmBeginDownloading() for the device refuses rather than starting a second thread over it, and
 * OmShutdown() still gets its own chance to reap it.  OM_E_ABORT says just that: the cancellation
 * was delivered, the thread has not stopped yet.
 *
 * Note this no longer answers OM_E_INVALID_DEVICE for a device that has already gone: cancelling
 * the download of a device that was just unplugged is exactly when the call has to work.
 */
int OmCancelDownload(int deviceId)
{
    // Check system and device state
    if (!om.initialized) return OM_E_NOT_VALID_STATE;
	OmDeviceState *device = OmDevice(deviceId);
	if (device == NULL) return OM_E_INVALID_DEVICE;   // Device never seen

    OmDownloadRequestCancel(device);
    if (!OmDownloadJoinBounded(device, OM_DOWNLOAD_JOIN_TIMEOUT_MS)) { return OM_E_ABORT; }
    return OM_OK;
}


/** PATCH (omgui-mac) H1/H2: ask a running download to stop, without waiting for it.
 *
 *  This is what the device-removal path calls.  It runs on the IOKit run-loop thread, where a join
 *  is not merely slow but wrong: while that thread is blocked no attach or detach notification is
 *  delivered and no CFRunLoopStop() is processed, so C3's unbounded join there turned an unplug
 *  during a download into a wedged discovery thread and, on the following Cmd-Q, a free() under two
 *  live threads.  The authoritative join lives in OmShutdown() (or in the next
 *  OmBeginDownloading() for this device), never here.
 *
 *  Invalidating the source descriptor is what keeps that later join short.  The copy loop tests
 *  downloadCancel once per block, so a cancel is only as prompt as the read in flight, and a read
 *  from a volume that has just been yanked is the case that matters.  dup2()'ing /dev/null over the
 *  descriptor makes every subsequent read report end-of-file, which the loop turns into a break,
 *  and -- unlike fclose()ing the stream or close()ing the descriptor out from under a thread that
 *  is inside fread() -- it neither tears down stdio state another thread owns nor frees a
 *  descriptor number that could be reused.  om.downloadMutex is held so the stream cannot be closed
 *  and cleared by the thread's own epilogue while we are reading it.
 */
void OmDownloadRequestCancel(OmDeviceState *device)
{
    unsigned int deviceId;

    if (device == NULL) { return; }
    deviceId = device->id;

    mutex_lock(&om.downloadMutex);
    device->downloadCancel = 1;
#if !defined(_WIN32)
    if (device->downloadSource != NULL)
    {
        int sourceFd = fileno(device->downloadSource);
        if (sourceFd >= 0)
        {
            int nullFd = open("/dev/null", O_RDONLY);
            if (nullFd >= 0)
            {
                if (dup2(nullFd, sourceFd) < 0)
                {
                    OmLog(3, "OmDownloadRequestCancel(%u) could not invalidate the source.\n", deviceId);
                }
                close(nullFd);
            }
        }
    }
#endif
    mutex_unlock(&om.downloadMutex);
    OmLog(3, "OmDownloadRequestCancel(%u) requested.\n", deviceId);
}


/** PATCH (omgui-mac) H3: bounded wait for the download thread to release the device state. */
int OmDownloadWaitFinished(OmDeviceState *device, unsigned long timeoutMs)
{
    int finished;

    if (device == NULL) { return 1; }
#if !defined(_WIN32)
    {
        struct timeval now;
        struct timespec deadline;

        gettimeofday(&now, NULL);
        deadline.tv_sec = now.tv_sec + (time_t)(timeoutMs / 1000);
        deadline.tv_nsec = (long)now.tv_usec * 1000L + (long)(timeoutMs % 1000) * 1000000L;
        while (deadline.tv_nsec >= 1000000000L) { deadline.tv_nsec -= 1000000000L; deadline.tv_sec++; }

        pthread_mutex_lock(&gDownloadDoneMutex);
        while (!device->downloadFinished)
        {
            if (pthread_cond_timedwait(&gDownloadDoneCond, &gDownloadDoneMutex, &deadline) == ETIMEDOUT) { break; }
        }
        finished = device->downloadFinished ? 1 : 0;
        pthread_mutex_unlock(&gDownloadDoneMutex);
    }
#else
    {
        unsigned long waited;
        for (waited = 0; !device->downloadFinished && waited < timeoutMs; waited += 10) { usleep(10 * 1000); }
        finished = device->downloadFinished ? 1 : 0;
    }
#endif
    return finished;
}


/** PATCH (omgui-mac) H1/H3: the one authoritative reap.
 *
 *  Darwin has no pthread_timedjoin_np(), so the bound is on the thread's own downloadFinished
 *  publication rather than on the join: once that flag is up the thread has closed both streams,
 *  delivered its final status and stopped touching the state, so the join that follows returns
 *  immediately.  On timeout the thread is detached and zero returned -- the caller must leak this
 *  OmDeviceState and must not destroy a mutex the orphan can still take.  Leaking a few kilobytes
 *  on a quit that was already going wrong beats freeing memory under a live fread().
 */
int OmDownloadJoinBounded(OmDeviceState *device, unsigned long timeoutMs)
{
    thread_t thread;
    unsigned int deviceId;

    if (device == NULL) { return 1; }
    if (!device->downloadThreadActive) { return 1; }        // No download thread to reap
    deviceId = device->id;

    // The handle is taken under the download mutex but waited on outside it: the download thread's
    // own epilogue takes the same mutex, so holding it here would deadlock.
    thread = OmDownloadTakeThread(device, deviceId);

    if (!OmDownloadWaitFinished(device, timeoutMs))
    {
        // The handle is released so the thread's resources come back when it eventually ends, but
        // downloadThreadActive deliberately stays up: it means "a thread exists that has not
        // published downloadFinished", so a later reap of the same state still refuses to declare
        // it free-able rather than being fooled by an already-detached handle.
        OmLog(0, "WARNING: Download thread for device %u did not stop in %lu ms; detaching it and leaking its state.\n", deviceId, timeoutMs);
        if (thread) { thread_detach(thread); }
        return 0;
    }

    if (thread)
    {
        OmLog(3, "OmDownloadJoinBounded(%u) joining download thread...\n", deviceId);
        thread_join(thread, NULL);
    }
    device->downloadThreadActive = 0;
    return 1;
}


/** PATCH (omgui-mac) C3, superseded by H1/H3.  Kept as the single-call spelling for a caller that
 *  is *not* on the discovery run-loop thread; the return value says whether the state may be
 *  freed. */
void OmDownloadCancelJoin(OmDeviceState *device)
{
    OmDownloadRequestCancel(device);
    (void)OmDownloadJoinBounded(device, OM_DOWNLOAD_JOIN_TIMEOUT_MS);
}


OmReaderHandle OmReaderOpenDeviceData(int deviceId)
{
    char filenameBuffer[OM_MAX_PATH];       // PATCH (omgui-mac) C13: was a bare 256
    int status;
    status = OmGetDataFilename(deviceId, filenameBuffer);
    if (OM_FAILED(status)) { return NULL; }
    return OmReaderOpen(filenameBuffer);
}
