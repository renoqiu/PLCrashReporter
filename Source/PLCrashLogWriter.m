/*
 * Author: Landon Fuller <landonf@plausiblelabs.com>
 *
 * Copyright (c) 2008-2012 Plausible Labs Cooperative, Inc.
 * All rights reserved.
 *
 * Permission is hereby granted, free of charge, to any person
 * obtaining a copy of this software and associated documentation
 * files (the "Software"), to deal in the Software without
 * restriction, including without limitation the rights to use,
 * copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following
 * conditions:
 *
 * The above copyright notice and this permission notice shall be
 * included in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 * EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
 * OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 * NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 * HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
 * WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
 * OTHER DEALINGS IN THE SOFTWARE.
 */

#import <stdlib.h>
#import <fcntl.h>
#import <errno.h>
#import <string.h>
#import <stdbool.h>
#import <dlfcn.h>

#import <sys/sysctl.h>
#import <sys/time.h>

#import <mach-o/dyld.h>

#import <libkern/OSAtomic.h>

#import "PLCrashReport.h"
#import "PLCrashLogWriter.h"
#import "PLCrashLogWriterEncoding.h"
#import "PLCrashAsync.h"
#import "PLCrashAsyncSignalInfo.h"
#import "PLCrashFrameWalker.h"

#import "PLCrashSysctl.h"

#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h> // For UIDevice
#endif

/**
 * @internal
 * Maximum number of frames that will be written to the crash report for a single thread. Used as a safety measure
 * to avoid overrunning our output limit when writing a crash report triggered by frame recursion.
 */
#define MAX_THREAD_FRAMES 512 // matches Apple's crash reporting on Snow Leopard

/**
 * @internal
 * Protobuf Field IDs, as defined in crashreport.proto
 */
enum {
    /** CrashReport.system_info */
    PLCRASH_PROTO_SYSTEM_INFO_ID = 1,

    /** CrashReport.system_info.operating_system */
    PLCRASH_PROTO_SYSTEM_INFO_OS_ID = 1,

    /** CrashReport.system_info.os_version */
    PLCRASH_PROTO_SYSTEM_INFO_OS_VERSION_ID = 2,

    /** CrashReport.system_info.architecture */
    PLCRASH_PROTO_SYSTEM_INFO_ARCHITECTURE_TYPE_ID = 3,

    /** CrashReport.system_info.timestamp */
    PLCRASH_PROTO_SYSTEM_INFO_TIMESTAMP_ID = 4,

    /** CrashReport.system_info.os_build */
    PLCRASH_PROTO_SYSTEM_INFO_OS_BUILD_ID = 5,

    /** CrashReport.app_info */
    PLCRASH_PROTO_APP_INFO_ID = 2,
    
    /** CrashReport.app_info.app_identifier */
    PLCRASH_PROTO_APP_INFO_APP_IDENTIFIER_ID = 1,
    
    /** CrashReport.app_info.app_version */
    PLCRASH_PROTO_APP_INFO_APP_VERSION_ID = 2,
    
    /** CrashReport.app_info.app_short_version */
    PLCRASH_PROTO_APP_INFO_APP_SHORT_VERSION_ID = 3,
    
    /** CrashReport.app_info.app_startup_timestamp */
    PLCRASH_PROTO_APP_INFO_APP_STARTUP_TIMESTAMP_ID = 4,


    /** CrashReport.threads */
    PLCRASH_PROTO_THREADS_ID = 3,
    

    /** CrashReports.thread.thread_number */
    PLCRASH_PROTO_THREAD_THREAD_NUMBER_ID = 1,

    /** CrashReports.thread.frames */
    PLCRASH_PROTO_THREAD_FRAMES_ID = 2,

    /** CrashReport.thread.crashed */
    PLCRASH_PROTO_THREAD_CRASHED_ID = 3,


    /** CrashReport.thread.frame.pc */
    PLCRASH_PROTO_THREAD_FRAME_PC_ID = 3,
    
    /** CrashReport.thread.frame.symbol */
    PLCRASH_PROTO_THREAD_FRAME_SYMBOL_NAME = 4,
    
    /** CrashReport.thread.frame.symbol_start */
    PLCRASH_PROTO_THREAD_FRAME_SYMBOL_START = 5,

    
    /** CrashReport.thread.registers */
    PLCRASH_PROTO_THREAD_REGISTERS_ID = 4,

    /** CrashReport.thread.register.name */
    PLCRASH_PROTO_THREAD_REGISTER_NAME_ID = 1,

    /** CrashReport.thread.register.name */
    PLCRASH_PROTO_THREAD_REGISTER_VALUE_ID = 2,


    /** CrashReport.images */
    PLCRASH_PROTO_BINARY_IMAGES_ID = 4,

    /** CrashReport.BinaryImage.base_address */
    PLCRASH_PROTO_BINARY_IMAGE_ADDR_ID = 1,

    /** CrashReport.BinaryImage.size */
    PLCRASH_PROTO_BINARY_IMAGE_SIZE_ID = 2,

    /** CrashReport.BinaryImage.name */
    PLCRASH_PROTO_BINARY_IMAGE_NAME_ID = 3,
    
    /** CrashReport.BinaryImage.uuid */
    PLCRASH_PROTO_BINARY_IMAGE_UUID_ID = 4,

    /** CrashReport.BinaryImage.code_type */
    PLCRASH_PROTO_BINARY_IMAGE_CODE_TYPE_ID = 5,

    
    /** CrashReport.exception */
    PLCRASH_PROTO_EXCEPTION_ID = 5,

    /** CrashReport.exception.name */
    PLCRASH_PROTO_EXCEPTION_NAME_ID = 1,
    
    /** CrashReport.exception.reason */
    PLCRASH_PROTO_EXCEPTION_REASON_ID = 2,
    
    /** CrashReports.exception.frames */
    PLCRASH_PROTO_EXCEPTION_FRAMES_ID = 3,


    /** CrashReport.signal */
    PLCRASH_PROTO_SIGNAL_ID = 6,

    /** CrashReport.signal.name */
    PLCRASH_PROTO_SIGNAL_NAME_ID = 1,

    /** CrashReport.signal.code */
    PLCRASH_PROTO_SIGNAL_CODE_ID = 2,
    
    /** CrashReport.signal.address */
    PLCRASH_PROTO_SIGNAL_ADDRESS_ID = 3,
    
    
    /** CrashReport.process_info */
    PLCRASH_PROTO_PROCESS_INFO_ID = 7,
    
    /** CrashReport.process_info.process_name */
    PLCRASH_PROTO_PROCESS_INFO_PROCESS_NAME_ID = 1,
    
    /** CrashReport.process_info.process_id */
    PLCRASH_PROTO_PROCESS_INFO_PROCESS_ID_ID = 2,
    
    /** CrashReport.process_info.process_path */
    PLCRASH_PROTO_PROCESS_INFO_PROCESS_PATH_ID = 3,
    
    /** CrashReport.process_info.parent_process_name */
    PLCRASH_PROTO_PROCESS_INFO_PARENT_PROCESS_NAME_ID = 4,
    
    /** CrashReport.process_info.parent_process_id */
    PLCRASH_PROTO_PROCESS_INFO_PARENT_PROCESS_ID_ID = 5,
    
    /** CrashReport.process_info.native */
    PLCRASH_PROTO_PROCESS_INFO_NATIVE_ID = 6,

    
    /** CrashReport.Processor.encoding */
    PLCRASH_PROTO_PROCESSOR_ENCODING_ID = 1,
    
    /** CrashReport.Processor.encoding */
    PLCRASH_PROTO_PROCESSOR_TYPE_ID = 2,
    
    /** CrashReport.Processor.encoding */
    PLCRASH_PROTO_PROCESSOR_SUBTYPE_ID = 3,


    /** CrashReport.machine_info */
    PLCRASH_PROTO_MACHINE_INFO_ID = 8,

    /** CrashReport.machine_info.model */
    PLCRASH_PROTO_MACHINE_INFO_MODEL_ID = 1,

    /** CrashReport.machine_info.processor */
    PLCRASH_PROTO_MACHINE_INFO_PROCESSOR_ID = 2,

    /** CrashReport.machine_info.processor_count */
    PLCRASH_PROTO_MACHINE_INFO_PROCESSOR_COUNT_ID = 3,

    /** CrashReport.machine_info.logical_processor_count */
    PLCRASH_PROTO_MACHINE_INFO_LOGICAL_PROCESSOR_COUNT_ID = 4,
    
    
    /** CrashReport.report_info */
    PLCRASH_PROTO_REPORT_INFO_ID = 9,
    
    /** CrashReport.report_info.report_guid */
    PLCRASH_PROTO_REPORT_INFO_REPORT_GUID_ID = 1,
};

/**
 * Initialize a new crash log writer instance and issue a memory barrier upon completion. This fetches all necessary
 * environment information.
 *
 * @param writer Writer instance to be initialized.
 * @param app_identifier Unique per-application identifier. On Mac OS X, this is likely the CFBundleIdentifier.
 * @param app_version Application version string.
 * @param app_short_version Application short version string.
 * @param app_startup_timestamp Application startup timestamp.
 * @param report_guid Crash Report GUID string.
 *
 * @note If this function fails, plcrash_log_writer_free() should be called
 * to free any partially allocated data.
 *
 * @warning This function is not guaranteed to be async-safe, and must be called prior to enabling the crash handler.
 */
plcrash_error_t plcrash_log_writer_init (plcrash_log_writer_t *writer, NSString *app_identifier, NSString *app_version, NSString *app_short_version, time_t app_startup_timestamp, NSString *report_guid) {
    /* Default to 0 */
    memset(writer, 0, sizeof(*writer));
    
    /* Fetch the crash report information */
    {
        writer->report_info.report_guid = strdup([report_guid UTF8String]);
    }
    
    /* Fetch the application information */
    {
        writer->application_info.app_identifier = strdup([app_identifier UTF8String]);
        writer->application_info.app_version = strdup([app_version UTF8String]);
        writer->application_info.app_short_version = strdup([app_short_version UTF8String]);
        writer->application_info.app_startup_timestamp = app_startup_timestamp;
    }
    
    /* Fetch the process information */
    {
        /* MIB used to fetch process info */
        struct kinfo_proc process_info;
        size_t process_info_len = sizeof(process_info);
        int process_info_mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, 0 };
        int process_info_mib_len = 4;

        /* Current process */
        {            
            /* Retrieve PID */
            writer->process_info.process_id = getpid();

            /* Retrieve name */
            process_info_mib[3] = writer->process_info.process_id;
            if (sysctl(process_info_mib, process_info_mib_len, &process_info, &process_info_len, NULL, 0) == 0) {
                writer->process_info.process_name = strdup(process_info.kp_proc.p_comm);
            } else {
                PLCF_DEBUG("Could not retreive process name: %s", strerror(errno));
            }

            /* Retrieve path */
            char *process_path = NULL;
            uint32_t process_path_len = 0;

            _NSGetExecutablePath(NULL, &process_path_len);
            if (process_path_len > 0) {
                process_path = malloc(process_path_len);
                _NSGetExecutablePath(process_path, &process_path_len);
                writer->process_info.process_path = process_path;
            }
        }

        /* Parent process */
        {            
            /* Retrieve PID */
            writer->process_info.parent_process_id = getppid();

            /* Retrieve name */
            process_info_mib[3] = writer->process_info.parent_process_id;
            if (sysctl(process_info_mib, process_info_mib_len, &process_info, &process_info_len, NULL, 0) == 0) {
                writer->process_info.parent_process_name = strdup(process_info.kp_proc.p_comm);
            } else {
                PLCF_DEBUG("Could not retreive parent process name: %s", strerror(errno));
            }

        }
    }

    /* Fetch the machine information */
    {
        /* Model */
#if TARGET_OS_IPHONE
        /* On iOS, we want hw.machine (e.g. hw.machine = iPad2,1; hw.model = K93AP) */
        writer->machine_info.model = plcrash_sysctl_string("hw.machine");
#else
        /* On Mac OS X, we want hw.model (e.g. hw.machine = x86_64; hw.model = Macmini5,3) */
        writer->machine_info.model = plcrash_sysctl_string("hw.model");
#endif
        if (writer->machine_info.model == NULL) {
            PLCF_DEBUG("Could not retrive hw.model: %s", strerror(errno));
        }
        
        /* CPU */
        {
            int retval;

            /* Fetch the CPU types */
            if (plcrash_sysctl_int("hw.cputype", &retval)) {
                writer->machine_info.cpu_type = retval;
            } else {
                PLCF_DEBUG("Could not retrive hw.cputype: %s", strerror(errno));
            }
            
            if (plcrash_sysctl_int("hw.cpusubtype", &retval)) {
                writer->machine_info.cpu_subtype = retval;
            } else {
                PLCF_DEBUG("Could not retrive hw.cpusubtype: %s", strerror(errno));
            }

            /* Processor count */
            if (plcrash_sysctl_int("hw.physicalcpu_max", &retval)) {
                writer->machine_info.processor_count = retval;
            } else {
                PLCF_DEBUG("Could not retrive hw.physicalcpu_max: %s", strerror(errno));
            }

            if (plcrash_sysctl_int("hw.logicalcpu_max", &retval)) {
                writer->machine_info.logical_processor_count = retval;
            } else {
                PLCF_DEBUG("Could not retrive hw.logicalcpu_max: %s", strerror(errno));
            }
        }
        
        /*
         * Check if the process is emulated. This sysctl is defined in the Universal Binary Programming Guidelines,
         * Second Edition:
         *
         * http://developer.apple.com/legacy/mac/library/documentation/MacOSX/Conceptual/universal_binary/universal_binary.pdf
         */
        {
            int retval;

            if (plcrash_sysctl_int("sysctl.proc_native", &retval)) {
                if (retval == 0) {
                    writer->process_info.native = false;
                } else {
                    writer->process_info.native = true;
                }
            } else {
                /* If the sysctl is not available, the process can be assumed to be native. */
                writer->process_info.native = true;
            }
        }
    }

    /* Fetch the OS information */    
    writer->system_info.build = plcrash_sysctl_string("kern.osversion");
    if (writer->system_info.build == NULL) {
        PLCF_DEBUG("Could not retrive kern.osversion: %s", strerror(errno));
    }

#if TARGET_OS_IPHONE
    /* iPhone OS */
    writer->system_info.version = strdup([[[UIDevice currentDevice] systemVersion] UTF8String]);
#elif TARGET_OS_MAC
    /* Mac OS X */
    {
        SInt32 major, minor, bugfix;

        /* Fetch the major, minor, and bugfix versions.
         * Fetching the OS version should not fail. */
        if (Gestalt(gestaltSystemVersionMajor, &major) != noErr) {
            PLCF_DEBUG("Could not retreive system major version with Gestalt");
            return PLCRASH_EINTERNAL;
        }
        if (Gestalt(gestaltSystemVersionMinor, &minor) != noErr) {
            PLCF_DEBUG("Could not retreive system minor version with Gestalt");
            return PLCRASH_EINTERNAL;
        }
        if (Gestalt(gestaltSystemVersionBugFix, &bugfix) != noErr) {
            PLCF_DEBUG("Could not retreive system bugfix version with Gestalt");
            return PLCRASH_EINTERNAL;
        }

        /* Compose the string */
        asprintf(&writer->system_info.version, "%" PRId32 ".%" PRId32 ".%" PRId32, (int32_t)major, (int32_t)minor, (int32_t)bugfix);
    }
#else
#error Unsupported Platform
#endif
    
    /* Initialize the image info list. */
    plcrash_async_image_list_init(&writer->image_info.image_list);

    /* Ensure that any signal handler has a consistent view of the above initialization. */
    OSMemoryBarrier();

    return PLCRASH_ESUCCESS;
}

/**
 * Register a binary image with this writer.
 *
 * @param writer The writer to which the image's information will be added.
 * @param header_addr The image's address.
 *
 * @warning This function is not async safe, and must be called outside of a signal handler.
 */
void plcrash_log_writer_add_image (plcrash_log_writer_t *writer, const void *header_addr) {
	plcrash_macho_image_t image;
    
    /* Parse the image */
    plcrash_macho_image_read_from_header(&image, (uintptr_t)header_addr);
    
    /* Register the image */
    plcrash_async_image_list_append(&writer->image_info.image_list, &image);
}

/**
 * Deregister a binary image from this writer.
 *
 * @param writer The writer from which the image's information will be removed.
 * @param header_addr The image's address.
 *
 * @warning This function is not async safe, and must be called outside of a signal handler.
 */
void plcrash_log_writer_remove_image (plcrash_log_writer_t *writer, const void *header_addr) {
    plcrash_async_image_list_remove(&writer->image_info.image_list, (uintptr_t)header_addr);
}

/**
 * Set the uncaught exception for this writer. Once set, this exception will be used to
 * provide exception data for the crash log output.
 *
 * @warning This function is not async safe, and must be called outside of a signal handler.
 */
void plcrash_log_writer_set_exception (plcrash_log_writer_t *writer, NSException *exception) {
    assert(writer->uncaught_exception.has_exception == false);

    /* Save the exception data */
    writer->uncaught_exception.has_exception = true;
    writer->uncaught_exception.name = strdup([[exception name] UTF8String]);
    writer->uncaught_exception.reason = strdup([[exception reason] UTF8String]);

    /* Save the call stack, if available */
    NSArray *callStackArray = [exception callStackReturnAddresses];
    if (callStackArray != nil && [callStackArray count] > 0) {
        size_t count = [callStackArray count];
        writer->uncaught_exception.callstack_count = count;
        writer->uncaught_exception.callstack = malloc(sizeof(void *) * count);

        size_t i = 0;
        for (NSNumber *num in callStackArray) {
            assert(i < count);
            
            uintptr_t pc = [num unsignedLongLongValue];
            
            /* When encountering any call stack entry which is not a valid
               symbol, stop. Exception backtraces tend to contain garbage at the
               end. Do NOT stop if symbol information was just unavailable. */
            if (tinyunw_get_symbol_info(pc - 1, NULL, NULL) == TINYUNW_EINVALIDIP)
                break;
            writer->uncaught_exception.callstack[i] = (void *)pc;
            i++;
        }
        writer->uncaught_exception.callstack_count = i;
    }

    /* Ensure that any signal handler has a consistent view of the above initialization. */
    OSMemoryBarrier();
}

/**
 * Close the plcrash_writer_t output.
 *
 * @param writer Writer instance to be closed.
 */
plcrash_error_t plcrash_log_writer_close (plcrash_log_writer_t *writer) {
    return PLCRASH_ESUCCESS;
}

/**
 * Free any crash log writer resources.
 *
 * @warning This method is not async safe.
 */
void plcrash_log_writer_free (plcrash_log_writer_t *writer) {
    /* Free the report info */
    if (writer->report_info.report_guid != NULL)
        free(writer->report_info.report_guid);
    
    /* Free the app info */
    if (writer->application_info.app_identifier != NULL)
        free(writer->application_info.app_identifier);
    if (writer->application_info.app_version != NULL)
        free(writer->application_info.app_version);
    if (writer->application_info.app_short_version != NULL)
        free(writer->application_info.app_short_version);

    /* Free the process info */
    if (writer->process_info.process_name != NULL) 
        free(writer->process_info.process_name);
    if (writer->process_info.process_path != NULL) 
        free(writer->process_info.process_path);
    if (writer->process_info.parent_process_name != NULL) 
        free(writer->process_info.parent_process_name);
    
    /* Free the system info */
    if (writer->system_info.version != NULL)
        free(writer->system_info.version);
    
    if (writer->system_info.build != NULL)
        free(writer->system_info.build);
    
    /* Free the machine info */
    if (writer->machine_info.model != NULL)
        free(writer->machine_info.model);

    /* Free the binary image info */
    plcrash_async_image_list_free(&writer->image_info.image_list);

    /* Free the exception data */
    if (writer->uncaught_exception.has_exception) {
        if (writer->uncaught_exception.name != NULL)
            free(writer->uncaught_exception.name);

        if (writer->uncaught_exception.reason != NULL)
            free(writer->uncaught_exception.reason);
        
        if (writer->uncaught_exception.callstack != NULL)
            free(writer->uncaught_exception.callstack);
    }
}

/**
 * @internal
 *
 * Write the report info message.
 *
 * @param file Output file
 * @param report_guid Crash Report GUID
 */
static size_t plcrash_writer_write_report_info (plcrash_async_file_t *file, const char *report_guid) {
    size_t rv = 0;
    
    /* Report GUID */
    rv += plcrash_writer_pack(file, PLCRASH_PROTO_REPORT_INFO_REPORT_GUID_ID, PLPROTOBUF_C_TYPE_STRING, report_guid);
    
    return rv;
}

/**
 * @internal
 *
 * Write the system info message.
 *
 * @param file Output file
 * @param timestamp Timestamp to use (seconds since epoch). Must be same across calls, as varint encoding.
 */
static size_t plcrash_writer_write_system_info (plcrash_async_file_t *file, plcrash_log_writer_t *writer, int64_t timestamp) {
    size_t rv = 0;
    uint32_t enumval;

    /* OS */
    enumval = PLCrashReportHostOperatingSystem;
    rv += plcrash_writer_pack(file, PLCRASH_PROTO_SYSTEM_INFO_OS_ID, PLPROTOBUF_C_TYPE_ENUM, &enumval);

    /* OS Version */
    rv += plcrash_writer_pack(file, PLCRASH_PROTO_SYSTEM_INFO_OS_VERSION_ID, PLPROTOBUF_C_TYPE_STRING, writer->system_info.version);
    
    /* OS Build */
    rv += plcrash_writer_pack(file, PLCRASH_PROTO_SYSTEM_INFO_OS_BUILD_ID, PLPROTOBUF_C_TYPE_STRING, writer->system_info.build);

    /* Machine type */
    enumval = PLCrashReportHostArchitecture;
    rv += plcrash_writer_pack(file, PLCRASH_PROTO_SYSTEM_INFO_ARCHITECTURE_TYPE_ID, PLPROTOBUF_C_TYPE_ENUM, &enumval);

    /* Timestamp */
    rv += plcrash_writer_pack(file, PLCRASH_PROTO_SYSTEM_INFO_TIMESTAMP_ID, PLPROTOBUF_C_TYPE_INT64, &timestamp);

    return rv;
}

/**
 * @internal
 *
 * Write the processor info message.
 *
 * @param file Output file
 * @param cpu_type The Mach CPU type.
 * @param cpu_subtype_t The Mach CPU subtype
 */
static size_t plcrash_writer_write_processor_info (plcrash_async_file_t *file, uint64_t cpu_type, uint64_t cpu_subtype) {
    size_t rv = 0;
    uint32_t enumval;
    
    /* Encoding */
    enumval = PLCrashReportProcessorTypeEncodingMach;
    rv += plcrash_writer_pack(file, PLCRASH_PROTO_PROCESSOR_ENCODING_ID, PLPROTOBUF_C_TYPE_ENUM, &enumval);

    /* Type */
    rv += plcrash_writer_pack(file, PLCRASH_PROTO_PROCESSOR_TYPE_ID, PLPROTOBUF_C_TYPE_UINT64, &cpu_type);

    /* Subtype */
    rv += plcrash_writer_pack(file, PLCRASH_PROTO_PROCESSOR_SUBTYPE_ID, PLPROTOBUF_C_TYPE_UINT64, &cpu_subtype);
    
    return rv;
}

/**
 * @internal
 *
 * Write the machine info message.
 *
 * @param file Output file
 */
static size_t plcrash_writer_write_machine_info (plcrash_async_file_t *file, plcrash_log_writer_t *writer) {
    size_t rv = 0;
    
    /* Model */
    if (writer->machine_info.model != NULL)
        rv += plcrash_writer_pack(file, PLCRASH_PROTO_MACHINE_INFO_MODEL_ID, PLPROTOBUF_C_TYPE_STRING, writer->machine_info.model);

    /* Processor */
    {
        uint32_t size;

        /* Determine size */
        size = plcrash_writer_write_processor_info(NULL, writer->machine_info.cpu_type, writer->machine_info.cpu_subtype);

        /* Write message */
        rv += plcrash_writer_pack(file, PLCRASH_PROTO_MACHINE_INFO_PROCESSOR_ID, PLPROTOBUF_C_TYPE_MESSAGE, &size);
        rv += plcrash_writer_write_processor_info(file, writer->machine_info.cpu_type, writer->machine_info.cpu_subtype);
    }

    /* Physical Processor Count */
    rv += plcrash_writer_pack(file, PLCRASH_PROTO_MACHINE_INFO_PROCESSOR_COUNT_ID, PLPROTOBUF_C_TYPE_UINT32, &writer->machine_info.processor_count);
    
    /* Logical Processor Count */
    rv += plcrash_writer_pack(file, PLCRASH_PROTO_MACHINE_INFO_LOGICAL_PROCESSOR_COUNT_ID, PLPROTOBUF_C_TYPE_UINT32, &writer->machine_info.logical_processor_count);
    
    return rv;
}

/**
 * @internal
 *
 * Write the app info message.
 *
 * @param file Output file
 * @param app_identifier Application identifier
 * @param app_version Application version
 * @param app_short_version Application short version
 * @param app_startup_timestamp Application startup timestsamp
 */
static size_t plcrash_writer_write_app_info (plcrash_async_file_t *file, const char *app_identifier, const char *app_version, const char *app_short_version, int64_t app_startup_timestamp) {
    size_t rv = 0;

    /* App identifier */
    rv += plcrash_writer_pack(file, PLCRASH_PROTO_APP_INFO_APP_IDENTIFIER_ID, PLPROTOBUF_C_TYPE_STRING, app_identifier);
    
    /* App version */
    rv += plcrash_writer_pack(file, PLCRASH_PROTO_APP_INFO_APP_VERSION_ID, PLPROTOBUF_C_TYPE_STRING, app_version);
    
    /* App short version */
    rv += plcrash_writer_pack(file, PLCRASH_PROTO_APP_INFO_APP_SHORT_VERSION_ID, PLPROTOBUF_C_TYPE_STRING, app_short_version);
    
    /* App startup timestamp */
    rv += plcrash_writer_pack(file, PLCRASH_PROTO_APP_INFO_APP_STARTUP_TIMESTAMP_ID, PLPROTOBUF_C_TYPE_INT64, &app_startup_timestamp);
    
    return rv;
}

/**
 * @internal
 *
 * Write the process info message.
 *
 * @param file Output file
 * @param process_name Process name
 * @param process_id Process ID
 * @param process_path Process path
 * @param parent_process_name Parent process name
 * @param parent_process_id Parent process ID
 * @param native If false, process is running under emulation.
 */
static size_t plcrash_writer_write_process_info (plcrash_async_file_t *file, const char *process_name, 
                                                 const pid_t process_id, const char *process_path, 
                                                 const char *parent_process_name, const pid_t parent_process_id,
                                                 bool native) 
{
    size_t rv = 0;

    /* Process name */
    if (process_name != NULL)
        rv += plcrash_writer_pack(file, PLCRASH_PROTO_PROCESS_INFO_PROCESS_NAME_ID, PLPROTOBUF_C_TYPE_STRING, process_name);

    /* Process ID */
    rv += plcrash_writer_pack(file, PLCRASH_PROTO_PROCESS_INFO_PROCESS_ID_ID, PLPROTOBUF_C_TYPE_UINT64, &process_id);

    /* Process path */
    if (process_path != NULL)
        rv += plcrash_writer_pack(file, PLCRASH_PROTO_PROCESS_INFO_PROCESS_PATH_ID, PLPROTOBUF_C_TYPE_STRING, process_path);

    /* Parent process name */
    if (parent_process_name != NULL)
        rv += plcrash_writer_pack(file, PLCRASH_PROTO_PROCESS_INFO_PARENT_PROCESS_NAME_ID, PLPROTOBUF_C_TYPE_STRING, parent_process_name);

    /* Parent process ID */
    rv += plcrash_writer_pack(file, PLCRASH_PROTO_PROCESS_INFO_PARENT_PROCESS_ID_ID, PLPROTOBUF_C_TYPE_UINT64, &parent_process_id);

    /* Native process. */
    rv += plcrash_writer_pack(file, PLCRASH_PROTO_PROCESS_INFO_NATIVE_ID, PLPROTOBUF_C_TYPE_BOOL, &native);

    return rv;
}

/**
 * @internal
 *
 * Write a thread backtrace register
 *
 * @param file Output file
 * @param cursor The cursor from which to acquire frame data.
 */
static size_t plcrash_writer_write_thread_register (plcrash_async_file_t *file, const char *regname, plframe_greg_t regval) {
    uint64_t uint64val;
    size_t rv = 0;

    /* Write the name */
    rv += plcrash_writer_pack(file, PLCRASH_PROTO_THREAD_REGISTER_NAME_ID, PLPROTOBUF_C_TYPE_STRING, regname);

    /* Write the value */
    uint64val = regval;
    rv += plcrash_writer_pack(file, PLCRASH_PROTO_THREAD_REGISTER_VALUE_ID, PLPROTOBUF_C_TYPE_UINT64, &uint64val);
    
    return rv;
}

/**
 * @internal
 *
 * Write all thread backtrace register messages
 *
 * @param file Output file
 * @param cursor The cursor from which to acquire frame data.
 */
static size_t plcrash_writer_write_thread_registers (plcrash_async_file_t *file, ucontext_t *uap, plcrash_log_writer_t *writer) {
    plframe_cursor_t cursor;
    plframe_error_t frame_err;
    uint32_t regCount;
    size_t rv = 0;

    /* Last is an index value, so increment to get the count */
    regCount = PLFRAME_REG_LAST + 1;

    /* Create the crashed thread frame cursor */
    if ((frame_err = plframe_cursor_init(&cursor, uap, &writer->image_info.image_list)) != PLFRAME_ESUCCESS) {
        PLCF_DEBUG("Failed to initialize frame cursor for crashed thread: %s", plframe_strerror(frame_err));
        return 0;
    }
    
    /* Fetch the first frame */
    if ((frame_err = plframe_cursor_next(&cursor)) != PLFRAME_ESUCCESS) {
        PLCF_DEBUG("Could not fetch crashed thread frame: %s", plframe_strerror(frame_err));
        return 0;
    }
    
    /* Write out register messages */
    for (int i = 0; i < regCount; i++) {
        plframe_greg_t regVal;
        const char *regname;
        uint32_t msgsize;

        /* Fetch the register value */
        if ((frame_err = plframe_get_reg(&cursor, i, &regVal)) != PLFRAME_ESUCCESS) {
            // Should never happen
            PLCF_DEBUG("Could not fetch register %i value: %s", i, plframe_strerror(frame_err));
            regVal = 0;
        }

        /* Fetch the register name */
        regname = plframe_get_regname(i);

        /* Get the register message size */
        msgsize = plcrash_writer_write_thread_register(NULL, regname, regVal);
        
        /* Write the header and message */
        rv += plcrash_writer_pack(file, PLCRASH_PROTO_THREAD_REGISTERS_ID, PLPROTOBUF_C_TYPE_MESSAGE, &msgsize);
        rv += plcrash_writer_write_thread_register(file, regname, regVal);
    }
    
    return rv;
}

/**
 * @internal
 *
 * Write a thread backtrace frame
 *
 * @param file Output file
 * @param pcval The frame PC value.
 */
static size_t plcrash_writer_write_thread_frame (plcrash_async_file_t *file, uint64_t pcval) {
    size_t rv = 0;
    plframe_greg_t symstart;
    uint64_t savesym;
    const char * symname;
    plframe_error_t err;

    rv += plcrash_writer_pack(file, PLCRASH_PROTO_THREAD_FRAME_PC_ID, PLPROTOBUF_C_TYPE_UINT64, &pcval);
    
    /* Use IP - 1 to account for the way exception throw instructions are
       emitted by the compiler. This can not produce a false symbol, as a crash
       must happen at least one instruction into a legitimate function, and
       addresses that are not in a legitimate function will never produce a
       useful symbol in any case. */
    if ((err = plframe_get_symbol(pcval - 1, &symstart, &symname)) == PLFRAME_ESUCCESS) {
        /* If we have a symbol, write its info. */
        savesym = symstart;
        rv += plcrash_writer_pack(file, PLCRASH_PROTO_THREAD_FRAME_SYMBOL_NAME, PLPROTOBUF_C_TYPE_STRING, symname);
        rv += plcrash_writer_pack(file, PLCRASH_PROTO_THREAD_FRAME_SYMBOL_START, PLPROTOBUF_C_TYPE_UINT64, &savesym);
    } else {
        PLCF_DEBUG("Couldn't get symbol for %llX got error: %s", pcval, plframe_strerror(err));
    }

    return rv;
}

/**
 * @internal
 *
 * Write a thread message
 *
 * @param file Output file
 * @param thread Thread for which we'll output data.
 * @param crashctx Context to use for currently running thread (rather than fetching the thread
 * context, which we've invalidated by running at all)
 */
static size_t plcrash_writer_write_thread (plcrash_async_file_t *file, thread_t thread, uint32_t thread_number, ucontext_t *crashctx, plcrash_log_writer_t *writer) {
    size_t rv = 0;
    plframe_cursor_t cursor;
    plframe_error_t ferr;
    bool crashed_thread = false;

    /* Write the required elements first; fatal errors may occur below, in which case we need to have
     * written out required elements before returning. */
    {
        /* Write the thread ID */
        rv += plcrash_writer_pack(file, PLCRASH_PROTO_THREAD_THREAD_NUMBER_ID, PLPROTOBUF_C_TYPE_UINT32, &thread_number);

        /* Is this the crashed thread? */
        thread_t thr_self = mach_thread_self();
        if (MACH_PORT_INDEX(thread) == MACH_PORT_INDEX(thr_self))
            crashed_thread = true;

        /* Note crashed status */
        rv += plcrash_writer_pack(file, PLCRASH_PROTO_THREAD_CRASHED_ID, PLPROTOBUF_C_TYPE_BOOL, &crashed_thread);
    }


    /* Write out the stack frames. */
    {
        /* Set up the frame cursor. */
        {
            /* Use the crashctx if we're running on the crashed thread */
            if (crashed_thread) {
                ferr = plframe_cursor_init(&cursor, crashctx, &writer->image_info.image_list);
            } else {
                ferr = plframe_cursor_thread_init(&cursor, thread, &writer->image_info.image_list);
            }

            /* Did cursor initialization succeed? If not, it is impossible to proceed */
            if (ferr != PLFRAME_ESUCCESS) {
                PLCF_DEBUG("An error occured initializing the frame cursor: %s", plframe_strerror(ferr));
                return rv;
            }
        }

        /* Walk the stack, limiting the total number of frames that are output. */
        uint32_t frame_count = 0;
        while ((ferr = plframe_cursor_next(&cursor)) == PLFRAME_ESUCCESS && frame_count < MAX_THREAD_FRAMES) {
            uint32_t frame_size;

            /* Fetch the PC value */
            plframe_greg_t pc = 0;
            if ((ferr = plframe_get_reg(&cursor, PLFRAME_REG_IP, &pc)) != PLFRAME_ESUCCESS) {
                PLCF_DEBUG("Could not retrieve frame PC register: %s", plframe_strerror(ferr));
                break;
            }

            /* Determine the size */
            frame_size = plcrash_writer_write_thread_frame(NULL, pc);
            
            rv += plcrash_writer_pack(file, PLCRASH_PROTO_THREAD_FRAMES_ID, PLPROTOBUF_C_TYPE_MESSAGE, &frame_size);
            rv += plcrash_writer_write_thread_frame(file, pc);
            frame_count++;
        }

        /* Did we reach the end successfully? */
        if (ferr != PLFRAME_ENOFRAME) {
            /* This is non-fatal, and in some circumstances -could- be caused by reaching the end of the stack if the
             * final frame pointer is not NULL. */
            PLCF_DEBUG("Terminated stack walking early: %s", plframe_strerror(ferr));
        }
    }

    /* Dump registers for the crashed thread */
    if (crashed_thread) {
        rv += plcrash_writer_write_thread_registers(file, crashctx, writer);
    }

    return rv;
}


/**
 * @internal
 *
 * Write a binary image frame
 *
 * @param file Output file
 * @param name binary image path (or name).
 * @param image_base Mach-O image base.
 */
static size_t plcrash_writer_write_binary_image (plcrash_async_file_t *file, plcrash_async_image_t *entry) {
    size_t rv = 0;
	
    rv += plcrash_writer_pack(file, PLCRASH_PROTO_BINARY_IMAGE_SIZE_ID, PLPROTOBUF_C_TYPE_UINT64, &entry->image.textsize);
    
    /* Base address */
    {
        uintptr_t base_addr;
        uint64_t u64;

        base_addr = (uintptr_t) entry->image.header;
        u64 = base_addr;
        rv += plcrash_writer_pack(file, PLCRASH_PROTO_BINARY_IMAGE_ADDR_ID, PLPROTOBUF_C_TYPE_UINT64, &u64);
    }

    /* Name */
    rv += plcrash_writer_pack(file, PLCRASH_PROTO_BINARY_IMAGE_NAME_ID, PLPROTOBUF_C_TYPE_STRING, entry->image.name);

    /* UUID */
    if (entry->image.hasUUID) {
        PLProtobufCBinaryData binary;
    
        /* Write the 128-bit UUID */
        binary.len = sizeof(entry->image.uuid);
        binary.data = entry->image.uuid;
        rv += plcrash_writer_pack(file, PLCRASH_PROTO_BINARY_IMAGE_UUID_ID, PLPROTOBUF_C_TYPE_BYTES, &binary);
    }
    
    /* Get the processor message size */
    uint32_t msgsize = plcrash_writer_write_processor_info(NULL, entry->image.cputype, entry->image.cpusubtype);

    /* Write the header and message */
    rv += plcrash_writer_pack(file, PLCRASH_PROTO_BINARY_IMAGE_CODE_TYPE_ID, PLPROTOBUF_C_TYPE_MESSAGE, &msgsize);
    rv += plcrash_writer_write_processor_info(file, entry->image.cputype, entry->image.cpusubtype);

    return rv;
}


/**
 * @internal
 *
 * Write the crash Exception message
 *
 * @param file Output file
 * @param writer Writer containing exception data
 */
static size_t plcrash_writer_write_exception (plcrash_async_file_t *file, plcrash_log_writer_t *writer) {
    size_t rv = 0;

    /* Write the name and reason */
    assert(writer->uncaught_exception.has_exception);
    rv += plcrash_writer_pack(file, PLCRASH_PROTO_EXCEPTION_NAME_ID, PLPROTOBUF_C_TYPE_STRING, writer->uncaught_exception.name);
    rv += plcrash_writer_pack(file, PLCRASH_PROTO_EXCEPTION_REASON_ID, PLPROTOBUF_C_TYPE_STRING, writer->uncaught_exception.reason);
    
    /* Write the stack frames, if any */
    uint32_t frame_count = 0;
    for (size_t i = 0; i < writer->uncaught_exception.callstack_count && frame_count < MAX_THREAD_FRAMES; i++) {
        uint64_t pc = (uint64_t)(uintptr_t) writer->uncaught_exception.callstack[i];
        
        /* Determine the size */
        uint32_t frame_size = plcrash_writer_write_thread_frame(NULL, pc);
        
        rv += plcrash_writer_pack(file, PLCRASH_PROTO_EXCEPTION_FRAMES_ID, PLPROTOBUF_C_TYPE_MESSAGE, &frame_size);
        rv += plcrash_writer_write_thread_frame(file, pc);
        frame_count++;
    }

    return rv;
}

/**
 * @internal
 *
 * Write the crash signal message
 *
 * @param file Output file
 * @param siginfo The signal information
 */
static size_t plcrash_writer_write_signal (plcrash_async_file_t *file, siginfo_t *siginfo) {
    size_t rv = 0;
    
    /* Fetch the signal name */
    char name_buf[10];
    const char *name;
    if ((name = plcrash_async_signal_signame(siginfo->si_signo)) == NULL) {
        PLCF_DEBUG("Warning -- unhandled signal number (signo=%d). This is a bug.", siginfo->si_signo);
        snprintf(name_buf, sizeof(name_buf), "#%d", siginfo->si_signo);
        name = name_buf;
    }

    /* Fetch the signal code string */
    char code_buf[10];
    const char *code;
    if ((code = plcrash_async_signal_sigcode(siginfo->si_signo, siginfo->si_code)) == NULL) {
        PLCF_DEBUG("Warning -- unhandled signal sicode (signo=%d, code=%d). This is a bug.", siginfo->si_signo, siginfo->si_code);
        snprintf(code_buf, sizeof(code_buf), "#%d", siginfo->si_code);
        code = code_buf;
    }
    
    /* Address value */
    uint64_t addr = (uintptr_t) siginfo->si_addr;

    /* Write it out */
    rv += plcrash_writer_pack(file, PLCRASH_PROTO_SIGNAL_NAME_ID, PLPROTOBUF_C_TYPE_STRING, name);
    rv += plcrash_writer_pack(file, PLCRASH_PROTO_SIGNAL_CODE_ID, PLPROTOBUF_C_TYPE_STRING, code);
    rv += plcrash_writer_pack(file, PLCRASH_PROTO_SIGNAL_ADDRESS_ID, PLPROTOBUF_C_TYPE_UINT64, &addr);

    return rv;
}

/**
 * Write the crash report. All other running threads are suspended while the crash report is generated.
 *
 * @param writer The writer context
 * @param file The output file.
 * @param siginfo Signal information
 * @param crashctx Context of the crashed thread.
 *
 * @warning This method must only be called from the thread that has triggered the crash. This must correspond
 * to the provided crashctx. Failure to adhere to this requirement will result in an invalid stack trace
 * and thread dump.
 */
plcrash_error_t plcrash_log_writer_write (plcrash_log_writer_t *writer, plcrash_async_file_t *file, siginfo_t *siginfo, ucontext_t *crashctx) {
    thread_act_array_t threads;
    mach_msg_type_number_t thread_count;

    /* File header */
    {
        uint8_t version = PLCRASH_REPORT_FILE_VERSION;

        /* Write the magic string (with no trailing NULL) and the version number */
        plcrash_async_file_write(file, PLCRASH_REPORT_FILE_MAGIC, strlen(PLCRASH_REPORT_FILE_MAGIC));
        plcrash_async_file_write(file, &version, sizeof(version));
    }

    /* Report Info */
    {
        uint32_t size;
        
        /* Determine size */
        size = plcrash_writer_write_report_info(NULL, writer->report_info.report_guid);
        
        /* Write message */
        plcrash_writer_pack(file, PLCRASH_PROTO_REPORT_INFO_ID, PLPROTOBUF_C_TYPE_MESSAGE, &size);
        plcrash_writer_write_report_info(file, writer->report_info.report_guid);
    }
    
    /* System Info */
    {
        time_t timestamp;
        uint32_t size;

        /* Must stay the same across both calls, so get the timestamp here */
        if (time(&timestamp) == (time_t)-1) {
            PLCF_DEBUG("Failed to fetch timestamp: %s", strerror(errno));
            timestamp = 0;
        }

        /* Determine size */
        size = plcrash_writer_write_system_info(NULL, writer, timestamp);
        
        /* Write message */
        plcrash_writer_pack(file, PLCRASH_PROTO_SYSTEM_INFO_ID, PLPROTOBUF_C_TYPE_MESSAGE, &size);
        plcrash_writer_write_system_info(file, writer, timestamp);
    }
    
    /* Machine Info */
    {
        uint32_t size;

        /* Determine size */
        size = plcrash_writer_write_machine_info(NULL, writer);

        /* Write message */
        plcrash_writer_pack(file, PLCRASH_PROTO_MACHINE_INFO_ID, PLPROTOBUF_C_TYPE_MESSAGE, &size);
        plcrash_writer_write_machine_info(file, writer);
    }

    /* App info */
    {
        uint32_t size;

        /* Determine size */
        size = plcrash_writer_write_app_info(NULL, writer->application_info.app_identifier, writer->application_info.app_version, writer->application_info.app_short_version, writer->application_info.app_startup_timestamp);
        
        /* Write message */
        plcrash_writer_pack(file, PLCRASH_PROTO_APP_INFO_ID, PLPROTOBUF_C_TYPE_MESSAGE, &size);
        plcrash_writer_write_app_info(file, writer->application_info.app_identifier, writer->application_info.app_version, writer->application_info.app_short_version, writer->application_info.app_startup_timestamp);
    }
    
    /* Process info */
    {
        uint32_t size;
        
        /* Determine size */
        size = plcrash_writer_write_process_info(NULL, writer->process_info.process_name, writer->process_info.process_id, 
                                                 writer->process_info.process_path, writer->process_info.parent_process_name,
                                                 writer->process_info.parent_process_id, writer->process_info.native);
        
        /* Write message */
        plcrash_writer_pack(file, PLCRASH_PROTO_PROCESS_INFO_ID, PLPROTOBUF_C_TYPE_MESSAGE, &size);
        plcrash_writer_write_process_info(file, writer->process_info.process_name, writer->process_info.process_id, 
                                          writer->process_info.process_path, writer->process_info.parent_process_name, 
                                          writer->process_info.parent_process_id, writer->process_info.native);
    }
    
    /* Threads */
    {
        task_t self = mach_task_self();
        thread_t self_thr = mach_thread_self();

        /* Get a list of all threads */
        if (task_threads(self, &threads, &thread_count) != KERN_SUCCESS) {
            PLCF_DEBUG("Fetching thread list failed");
            thread_count = 0;
        }

        /* Suspend each thread and write out its state */
        for (mach_msg_type_number_t i = 0; i < thread_count; i++) {
            thread_t thread = threads[i];
            uint32_t size;
            bool suspend_thread = true;
            
            /* Check if we're running on the to be examined thread */
            if (MACH_PORT_INDEX(self_thr) == MACH_PORT_INDEX(threads[i])) {
                suspend_thread = false;
            }
            
            /* Suspend the thread */
            if (suspend_thread && thread_suspend(threads[i]) != KERN_SUCCESS) {
                PLCF_DEBUG("Could not suspend thread %d", i);
                continue;
            }
            
            /* Determine the size */
            size = plcrash_writer_write_thread(NULL, thread, i, crashctx, writer);
            
            /* Write message */
            plcrash_writer_pack(file, PLCRASH_PROTO_THREADS_ID, PLPROTOBUF_C_TYPE_MESSAGE, &size);
            plcrash_writer_write_thread(file, thread, i, crashctx, writer);

            /* Resume the thread */
            if (suspend_thread)
                thread_resume(threads[i]);
        }
        
        /* Clean up the thread array */
        for (mach_msg_type_number_t i = 0; i < thread_count; i++)
            mach_port_deallocate(mach_task_self(), threads[i]);
        vm_deallocate(mach_task_self(), (vm_address_t)threads, sizeof(thread_t) * thread_count);
    }

    /* Binary Images */
    plcrash_async_image_list_set_reading(&writer->image_info.image_list, true);

    plcrash_async_image_t *image = NULL;
    while ((image = plcrash_async_image_list_next(&writer->image_info.image_list, image)) != NULL) {
        uint32_t size;

        /* Calculate the message size */
        // TODO - switch to plframe_read_addr()
        size = plcrash_writer_write_binary_image(NULL, image);
        plcrash_writer_pack(file, PLCRASH_PROTO_BINARY_IMAGES_ID, PLPROTOBUF_C_TYPE_MESSAGE, &size);
        plcrash_writer_write_binary_image(file, image);
    }

    plcrash_async_image_list_set_reading(&writer->image_info.image_list, false);

    /* Exception */
    if (writer->uncaught_exception.has_exception) {
        uint32_t size;

        /* Calculate the message size */
        size = plcrash_writer_write_exception(NULL, writer);
        plcrash_writer_pack(file, PLCRASH_PROTO_EXCEPTION_ID, PLPROTOBUF_C_TYPE_MESSAGE, &size);
        plcrash_writer_write_exception(file, writer);
    }
    
    /* Signal */
    {
        uint32_t size;
        
        /* Calculate the message size */
        size = plcrash_writer_write_signal(NULL, siginfo);
        plcrash_writer_pack(file, PLCRASH_PROTO_SIGNAL_ID, PLPROTOBUF_C_TYPE_MESSAGE, &size);
        plcrash_writer_write_signal(file, siginfo);
    }
    
    return PLCRASH_ESUCCESS;
}


/**
 * @} plcrash_log_writer
 */
