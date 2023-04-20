%%--------------------------------------------------------------------
%% Copyright (c) 2020 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------
-module(esockd_utils).

-export([explain_posix/1]).

explain_posix(eacces) -> "EACCES (Permission denied)";
explain_posix(eagain) -> "EAGAIN (Resource temporarily unavailable)";
explain_posix(ebadf) -> "EBADF (Bad file number)";
explain_posix(ebusy) -> "EBUSY (File busy)";
explain_posix(edquot) -> "EDQUOT (Disk quota exceeded)";
explain_posix(eexist) -> "EEXIST (File already exists)";
explain_posix(efault) -> "EFAULT (Bad address in system call argument)";
explain_posix(efbig) -> "EFBIG (File too large)";
explain_posix(eintr) -> "EINTR (Interrupted system call)";
explain_posix(einval) -> "EINVAL (Invalid argument argument file/socket)";
explain_posix(eio) -> "EIO (I/O error)";
explain_posix(eisdir) -> "EISDIR (Illegal operation on a directory)";
explain_posix(eloop) -> "ELOOP (Too many levels of symbolic links)";
explain_posix(emfile) -> "EMFILE (Too many open files)";
explain_posix(emlink) -> "EMLINK (Too many links)";
explain_posix(enametoolong) -> "ENAMETOOLONG (Filename too long)";
explain_posix(enfile) -> "ENFILE (File table overflow)";
explain_posix(enodev) -> "ENODEV (No such device)";
explain_posix(enoent) -> "ENOENT (No such file or directory)";
explain_posix(enomem) -> "ENOMEM (Not enough memory)";
explain_posix(enospc) -> "ENOSPC (No space left on device)";
explain_posix(enotblk) -> "ENOTBLK (Block device required)";
explain_posix(enotdir) -> "ENOTDIR (Not a directory)";
explain_posix(enotsup) -> "ENOTSUP (Operation not supported)";
explain_posix(enxio) -> "ENXIO (No such device or address)";
explain_posix(eperm) -> "EPERM (Not owner)";
explain_posix(epipe) -> "EPIPE (Broken pipe)";
explain_posix(erofs) -> "EROFS (Read-only file system)";
explain_posix(espipe) -> "ESPIPE (Invalid seek)";
explain_posix(esrch) -> "ESRCH (No such process)";
explain_posix(estale) -> "ESTALE (Stale remote file handle)";
explain_posix(exdev) -> "EXDEV (Cross-domain link)";
explain_posix(NotPosix) -> NotPosix.
