#!/usr/bin/env perl
#############################################################################
##
## Copyright (C) 2012 Nokia Corporation and/or its subsidiary(-ies).
## Contact: http://www.qt-project.org/
##
## This file is part of the Quality Assurance module of the Qt Toolkit.
##
## $QT_BEGIN_LICENSE:LGPL$
## GNU Lesser General Public License Usage
## This file may be used under the terms of the GNU Lesser General Public
## License version 2.1 as published by the Free Software Foundation and
## appearing in the file LICENSE.LGPL included in the packaging of this
## file. Please review the following information to ensure the GNU Lesser
## General Public License version 2.1 requirements will be met:
## http://www.gnu.org/licenses/old-licenses/lgpl-2.1.html.
##
## In addition, as a special exception, Nokia gives you certain additional
## rights. These rights are described in the Nokia Qt LGPL Exception
## version 1.1, included in the file LGPL_EXCEPTION.txt in this package.
##
## GNU General Public License Usage
## Alternatively, this file may be used under the terms of the GNU General
## Public License version 3.0 as published by the Free Software Foundation
## and appearing in the file LICENSE.GPL included in the packaging of this
## file. Please review the following information to ensure the GNU General
## Public License version 3.0 requirements will be met:
## http://www.gnu.org/copyleft/gpl.html.
##
## Other Usage
## Alternatively, this file may be used in accordance with the terms and
## conditions contained in a signed written agreement between you and Nokia.
##
##
##
##
##
##
## $QT_END_LICENSE$
##
#############################################################################

package QtQA::App::ParseBuildLog;

use 5.010;
use strict;
use warnings;

=head1 NAME

parse_build_log - extract the interesting parts from a build log

=head1 SYNOPSIS

  ./parse_build_log [options] <logfile>

  # e.g., given a very large build log, just extract the interesting lines:
  $ ./parse_build_log my-log.txt
  compiling qml/qdeclarativebinding.cpp
  qml/qdeclarativebinding.cpp: In static member function 'static QDeclarativeBinding* QDeclarativeBinding::createBinding(int, QObject*, QDeclarativeContext*, const QString&, int, QObject*)':
  qml/qdeclarativebinding.cpp:238: error: cannot convert 'QDeclarativeEngine*' to 'QDeclarativeEnginePrivate*' in initialization
  make[3]: *** [.obj/debug-shared/qdeclarativebinding.o] Error 1
  make[2]: *** [sub-declarative-make_default-ordered] Error 2
  make[1]: *** [module-qtdeclarative-src-make_default] Error 2
  make: *** [module-qtdeclarative] Error 2

  # Or perhaps attempt to summarize the error in human-readable format,
  # and directly load the log over HTTP:
  $ ./parse_build_log --summarize http://example.com/some-ci-system/linux-build-log.txt.gz
  qtdeclarative failed to compile on Linux:

    compiling qml/qdeclarativebinding.cpp
    qml/qdeclarativebinding.cpp: In static member function 'static QDeclarativeBinding* QDeclarativeBinding::createBinding(int, QObject*, QDeclarativeContext*, const QString&, int, QObject*)':
    qml/qdeclarativebinding.cpp:238: error: cannot convert 'QDeclarativeEngine*' to 'QDeclarativeEnginePrivate*' in initialization
    make[3]: *** [.obj/debug-shared/qdeclarativebinding.o] Error 1
    make[2]: *** [sub-declarative-make_default-ordered] Error 2
    make[1]: *** [module-qtdeclarative-src-make_default] Error 2
    make: *** [module-qtdeclarative] Error 2

This script takes a raw plain text or gzip-compressed build log and attempts to extract
the interesting parts, and possibly provide a nice human-readable summary of the failure.

=head1 OPTIONS

=over

=item B<--help>

Print this message.

=item B<--summarize>

If given, as well as printing out the interesting lines from the log, the script
will attempt to print out a human-readable summary of the error(s).

=item B<--limit> LINES

Limit the amount of extracted lines to the given value.
Use 0 for no limit.

If omitted, an undefined but reasonable default is used.

=item B<--debug>

Enable some debug messages to STDERR.
Use this to troubleshoot when some log is not parsed in the expected manner.

=back

=head1 CAVEATS

This script is entirely based on heuristics.  It may make mistakes.

=cut

use AnyEvent::HTTP;
use Data::Dumper;
use File::Basename;
use File::Slurp qw();
use Getopt::Long qw(GetOptionsFromArray);
use IO::Uncompress::AnyInflate qw(anyinflate $AnyInflateError);
use Lingua::EN::Inflect qw(inflect PL WORDLIST);
use Lingua::EN::Numbers qw(num2en);
use List::MoreUtils qw(any apply);
use Pod::Usage;
use Readonly;
use Text::Wrap;
use YAML qw();

# Contact details of some CI admins who can deal with problems.
# Put a public email address here once we have one!
Readonly my $CI_CONTACT
    => q{some CI administrator};

# The max amount of lines we're willing to buffer before giving up,
# when attempting to identify a related chunk of output (e.g. a single
# autotest log).
Readonly my $MAX_CHUNK_LINES => 5000;

# List of all common error strings returned by strerror();
# This may be generated by:
#
#   perl -mPOSIX -E 'for (my $i = 0; $i < 150; ++$i) { say POSIX::strerror($i) }'
#
# The strings should be collected from a few different platforms, as there
# are some platform-specific messages and some slight variations (e.g.
# "cannot" vs "can't").
#
# Note that these are matched case-insensitive, as certain tools seem to use
# messages from this list with slight differences in case.
#
Readonly my @POSIX_ERROR_STRINGS
    => split /\n/, <<'END_ERROR_STRINGS';
.lib section in a.out corrupted
Accessing a corrupted shared library
Address already in use
Address family not supported by protocol
Address family not supported by protocol family
Advertise error
Argument list too long
Attempting to link in too many shared libraries
Attribute not found
Authentication error
Bad CPU type in executable
Bad address
Bad executable (or shared library)
Bad file descriptor
Bad font file format
Bad message
Bad procedure for program
Block device required
Broken pipe
Can not access a needed shared library
Can't assign requested address
Can't send after socket shutdown
Cannot allocate memory
Cannot assign requested address
Cannot exec a shared library directly
Cannot send after transport endpoint shutdown
Channel number out of range
Communication error on send
Connection refused
Connection reset by peer
Connection timed out
Cross-device link
Destination address required
Device error
Device not a stream
Device not configured
Device or resource busy
Device power is off
Directory not empty
Disc quota exceeded
Disk quota exceeded
EMULTIHOP (Reserved)
ENOLINK (Reserved)
Exchange full
Exec format error
File descriptor in bad state
File exists
File name too long
File too large
Function not implemented
Host is down
Identifier removed
Illegal byte sequence
Illegal seek
Inappropriate file type or format
Inappropriate ioctl for device
Input/output error
Interrupted system call
Interrupted system call should be restarted
Invalid argument
Invalid cross-device link
Invalid exchange
Invalid or incomplete multibyte or wide character
Invalid request code
Invalid request descriptor
Invalid slot
Is a directory
Is a named type file
Key has been revoked
Key has expired
Key was rejected by service
Level 2 halted
Level 2 not synchronized
Level 3 halted
Level 3 reset
Link has been severed
Link number out of range
Machine is not on the network
Malformed Mach-o file
Message too long
Multihop attempted
Name not unique on network
Need authenticator
Network dropped connection on reset
Network is down
Network is unreachable
No CSI structure available
No STREAM resources
No XENIX semaphores available
No anode
No buffer space available
No child processes
No data available
No locks available
No medium found
No message available on STREAM
No message of desired type
No route to host
No space left on device
No such device
No such device or address
No such file or directory
No such process
Not a STREAM
Not a XENIX named type file
Not a directory
Numerical argument out of domain
Numerical result out of range
Object is remote
Operation already in progress
Operation canceled
Operation not permitted
Operation not supported
Operation not supported by device
Operation not supported on socket
Operation now in progress
Operation timed out
Out of streams resources
Owner died
Package not installed
Permission denied
Policy not found
Previous owner died
Program version wrong
Protocol driver not attached
Protocol error
Protocol family not supported
Protocol not available
Protocol not supported
Protocol wrong type for socket
RFS specific error
RPC prog. not avail
RPC struct is bad
RPC version wrong
Read-only file system
Remote I/O error
Remote address changed
Required key not available
Resource busy
Resource deadlock avoided
Resource temporarily unavailable
Result too large
STREAM ioctl timeout
Shared library version mismatch
Socket is already connected
Socket is not connected
Socket operation on non-socket
Socket type not supported
Software caused connection abort
Srmount error
Stale NFS file handle
State not recoverable
Streams pipe error
Structure needs cleaning
Text file busy
Timer expired
Too many levels of remote in path
Too many levels of symbolic links
Too many links
Too many open files
Too many open files in system
Too many processes
Too many references: can't splice
Too many references: cannot splice
Too many users
Transport endpoint is already connected
Transport endpoint is not connected
Unknown error 41
Unknown error 58
Value too large for defined data type
Value too large to be stored in data type
Wrong medium type
END_ERROR_STRINGS

# All important regular expressions used to extract errors
#Readonly my %RE => (  <- too slow :( Adds seconds to runtime, according to NYTProf.
my %RE = (

    # never matches anything
    never_match => qr{a\A}ms,


    # the kind of timestamp prefix used by Pulse.
    # example:
    #
    #  8/29/11 7:03:33 PM EST: Hi there
    #
    # matches up to and including the `: '
    #
    # Captures:
    #   date    -   the date string
    #   time    -   the time string (incl. AM/PM, and timezone)
    #
    pulse_timestamp => qr{
            \A

            (?<date>
                # d/m/y
                \d{1,2}/\d{1,2}/\d{1,2}
            )

            \s+

            (?<time>
                # h:m:s
                \d{1,2}:\d{1,2}:\d{1,2}

                \s+

                # AM or PM
                [AP]M

                \s+

                # some timezone (e.g. EST)
                [A-Z]{2,4}
            )

            # and the `: ' at the end
            :[ ]
    }xms,

    # Any kind of error in the Pulse configuration.
    #
    # Example:
    #   Recipe terminated with an error: Recipe request timed out waiting for a capable agent to become available.
    #
    # These kinds of errors are always the fault of the CI infrastructure
    # and not the code under test.
    #
    pulse_config_error => qr{
        (?:
            \A
            \QNo online agents satisfy the request requirements.\E
        )

        |

        (?:
            # Stage name in pulse doesn't match stage name in testconfig.git
            \A
            \s*
            \QCould not find a stage directory for \E
            .*
            \s at \s [^\s]+/test\.pl \s line \s \d+
        )

        # add more as discovered
    }xms,

    # Any kind of glitch which can be identified as the reason for the build failure,
    # but the underlying cause is unknown.
    #
    # This is a catch-all for any kind of errors where:
    #
    #  - we can recognize the error message, but don't know the cause, or:
    #
    #  - we roughly know the cause, but it's considered unfeasible to really fix the
    #    problem or confidently present more information about the problem.
    #
    glitch => qr{
        (?:
            # note, deliberately not anchored at \A - this can occur in the middle of a line!
            \QRecipe terminated with an error: \E
            (?:
                \QAgent status changed to 'invalid master' while recipe in progress\E
                |
                \QAgent idle before recipe expected to complete\E
            )
        )

        |

        (?:
            \QRecipe terminated with an error: Unable to dispatch recipe:\E
            [^\n]+
            \Qcom.caucho.hessian.io.HessianProtocolException: expected boolean at end of file\E
        )

        |

        (?:
            # Bizarre error on mac - see QTQAINFRA-376
            # Format is:
            #  cmd: cmd: cannot execute binary file
            # ... where "cmd" is a core utility, e.g. from /bin or /usr/bin.
            (?<cmd>
                (?:/usr)?
                /bin/[^: ]{0,50}
            )
            :[ ]
            \k<cmd>
            :[ ]
            \Qcannot execute binary file\E
        )

        |

        (?:
            # test.pl from testconfig can't be run;
            # usually means the testconfig repo couldn't be cloned for some reason.
            \QCan't open perl script "_testconfig/test.pl": No such file or directory\E
        )

        |

        (?:
            # setup.pl from qtqa can't be run;
            # Occurs when the qtqa repo couldn't be cloned for some reason.
            \QCan't open perl script "_qtqa_latest/scripts/setup.pl": No such file or directory\E
        )

        |

        (?:
            # testconfig directory can't be removed;
            # usually means the testconfig repo couldn't be cloned for some reason.
            \Qfatal: destination path '_testconfig' already exists and is not an empty directory.\E
        )

        |

        (?:
            # the bootstrap command fails to run;
            # this has a number of different triggers, however it won't be related to the code under test.
            \QCommand 'bootstrap' completed with status error\E
        )

        |

        (?:
            # the cloning of the qtqa repository failed;
            # this has a number of different triggers, however it won't be related to the code under test.
            git\ clone[^']+'\ exited\ with\ code\ \d+\ at\ .*[\\/]test\.pl
        )

        # add more as discovered
    }xms,

    # line output when the top-level qtqa script fails.
    #
    # Example:
    #   `perl _qtqa_latest/scripts/setup.pl --install && perl _qtqa_latest/scripts/qt/qtmod_test.pl' exited with code 3 at _pulseconfig/test.pl line 1025.
    #
    # Captures:
    #   qtqa_script -   path of the qtqa script which failed, relative to qtqa
    #                   (e.g. "scripts/qt/qtmod_test.pl")
    #
    qtqa_script_fail => qr{
        perl \s _qtqa_latest/

        (?<qtqa_script>
            [^']+
        )

        ' \s \Qexited with code \E\d
    }xms,

    # make failed.
    #
    # Examples:
    #   make[1]: *** [module-qtdeclarative-src-make_default] Error 2
    #   make: *** [module-qtdeclarative] Error 2
    #
    # Captures:
    #   make        -   the make tool (e.g. "make", "gmake"). ".exe" is omitted on windows
    #   sublevel    -   level of submake (e.g. "make[1]: *** Error 2" gives "1");
    #                   never matches for top-level make (not always available)
    #   target      -   make target which failed (not always available)
    #   errorlevel  -   the error number, e.g. "Error 2" gives "2", or
    #                   "fatal error U1077" from nmake gives U1077
    #                   (not always available)
    #   errortext   -   the error text, if any
    #
    # Caveats:
    #   nmake support is not very good; its output is inferior to gmake.
    #
    #   jom support is missing (it probably can't be added without modifying jom,
    #   as jom simply doesn't output enough info - tested with jom 0.9.3)
    #
    #   According to NYTProf, this regex is unusually slow ... why??
    #
    make_fail => qr{
        \A

        (?:

            (?<make>
                make
                |
                [gn]make        # GNU make, nmake
                |
                mingw32-make
            )

            (?: \.exe )?    # maybe has .exe on the end on Windows

            (?:
                \[
                (?<sublevel>
                    \d+
                )
                \]
            )?              # "[2]" etc only present for submakes

            :
            \s

            # *** is the thing indicating an error
            \*{3}
            \s

            (?:

                # now the target, in square brackets
                (?:
                    \[
                    (?<target>
                        [^\]]+
                    )
                    \]
                )

                \s

                (?:
                    # "Error <num>"
                    Error \s
                    (?<errorlevel>
                        \d+
                    )

                    |

                    # This comes when make itself segfaults
                    \QSegmentation fault: 11\E
                )

                |

                (?<errortext>
                    \QNo rule to make target `\E
                    [^']+
                    \Q', needed by `\E
                    (?<target>
                        [^']+
                    )
                    '
                    .+
                )
            )

        )

        |

        # nmake example:
        #  NMAKE : fatal error U1077: 'somecmd' : return code '0xff'
        (?i:
            (?<make>
                nmake
            )

            \s{0,20}
            :
            \s{0,20}

            \Qfatal error \E

            (?<errorlevel>
                [^:]{1,20}
            )

            \s{0,20}

            (?<errortext>
                .+
            )
        )

        \z
    }xms,

    # compile failed.
    #
    # Examples:
    #   quicktestresult.cpp:453: error: no matching function for call to 'QTestResult::addSkip(const char*, QTest::SkipMode, const char*, int&)'
    #   c:\test\recipes\129373577\base\qt\qtsvg\src\svg\qsvgstyle_p.h(65) : fatal error C1083: Cannot open include file: 'qdebug.h': No such file or directory
    #   /bin/sh: line 1: 52873 Killed: 9               g++ -c -pipe (...) graphicsview/qgraphicstransform.cpp
    #   mapsgl/frustum_p.h:60:27: error: Qt3D/qplane3d.h: No such file or directory
    #   qmetaobject/main.cpp:219: undefined reference to `QTreeView::staticMetaObject'
    #
    # Captures:
    #   file        -   name of the file in which error occurred (exactly as output by the
    #                   compiler - could be relative, absolute, missing, or totally bogus)
    #   line        -   line number at which the error occurred (if available)
    #   error       -   text of the error message
    #
    # Caveats:
    #   Only matches a single line of the error (so e.g. for an ambiguous overload, "error"
    #   will not contain any of the alternatives)
    #
    #   These can probably be screwed up by source files whose path contains characters
    #   used as message separators by the compiler (e.g. `:' or `(' ) ... so please do not
    #   name source files like this :)
    #
    compile_fail => qr{

        # gcc or similar
        (?:
            \A

            # foobar.cpp:123: error: quiznux
            (?<file>
                [^:]+
            )

            :

            (?<line>
                \d+
            )

            (?:         # It is possible to have more than one line number in the error, e.g:
                :\d+    #   mapsgl/frustum_p.h:60:27: (...)
            )*          # We do not capture them at the moment.

            : \s

            (?<error>
                (?:
                    # error strings may start with "fatal error:",
                    # "internal compiler error:" or just "error:"
                    (?:fatal\ |internal\ compiler\ )?
                    error: .+
                )
                |
                (?:
                    # note that `undefined reference' may produce either a compiler-style
                    # error message (caught here), or a linker-style error message (caught
                    # in linker_fail), depending on exactly when the error occurs
                    \Qundefined reference to \E.+
                )
            )

            \z
        )

        |

        # gcc killed for some reason
        (?:
            \A

            # note, assumes `make' is using `/bin/sh' (probably safe assumption)
            # /bin/sh: line 123: 456 Killed: 9
            /bin/sh:
            \s+

            line \s \d+:
            \s+

            \d+             # pid
            \s+

            (?<error>
                [^:]+       # description of the signal.  e.g. Killed, Aborted
                :
                \s+
                \d+         # signal number
            )

            \s+

            (?: gcc|g\+\+ ) # only catch gcc issues
            .+?             # rest of command and arguments ...

            (?<file>        # ...and assume file is the last argument (qmake-specific assumption)
                [^\s]+
            )

            \z
        )

        |

        # msvc or similar
        (?:
            \A

            #foobar.cpp(65) : fatal error C123: quiznux
            (?<file>
                [^\(]+
            )

            \(
            (?<line>
                \d+
            )
            \)

            \s*
            :
            \s*

            (?<error>
                # some errors include the word `fatal' and others don't,
                # though they all seem to be equally fatal.
                (?:fatal\s)?
                \Qerror C\E
                \d+
                .+
            )

            \z
        )

        |

        # GNU assembler errors (when used with -pipe)
        # example:
        #   \{standard input\}:12763: Error: thumb conditional instruction should be in IT block -- `strexheq r3,r5,[r6]'
        (?:
            \A

            (?<file>
                \Q\{standard input\}\E
            )

            :

            (?<line>
                \d+
            )

            :
            [ ]

            (?<error>
                \QError: \E
                .+
            )

            \z
        )

        |

        # cc1plus errors
        # example:
        #    cc1plus: error: unrecognized command line option "-Wlogical-op"
        (?:
            \A

            cc1plus:

            [ ]

            (?<error>
                \Qerror: \E
                .+
            )

            \z
        )

        # add more compilers here as needed

    }xms,

    # Continued lines from a compile failure.
    #
    # This matches the lines leading or following an initial compile fail message which
    # provide additional info about the failure.
    #
    # Examples:
    #   src/testlib/qtestresult_p.h:96: note: candidates are: static void QTestResult::addSkip(const char*, const char*, int)
    #
    #   In file included from mapsgl/map_p.h:59,
    #                    from mapsgl/map2d/map2d_p.h:55,
    #                    from mapsgl/map2d/map2d_p.cpp:41:
    #
    #   src/corelib/kernel/qvariant.h(254): could be 'QVariant::QVariant(QVariant &&)'
    #   src/corelib/kernel/qvariant.h(207): or       'QVariant::QVariant(int)'
    #          while trying to match the argument list '(QKeySequence)'
    #
    # Captures: nothing
    #
    # Caveats:
    #   Has false positives.
    #   This is considered acceptable because this pattern is only intended
    #   to be used in a very narrow scope (it should be applied only to lines
    #   surrounding something which matches compile_fail).
    #
    compile_fail_continuation => qr{
        (?:
            \Q: note: \E
        )

        |

        (?:
            \A
            \s*
            (?:
                \QIn file included \E
                |
                \s+
            )
            from
            \s
            [^\s]+:\d+  # some/file.cpp:123
            [,:]        # , or : depending on whether it's the last line
            \s*
            \z
        )

        |

        (?:
            # MSVC providing context from an earlier error.
            # example:
            #
            #   winsock2.h(2370) : error C2375: 'WSAAsyncGetServByPort' : redefinition; different linkage
            #   winsock.h(901) : see declaration of 'WSAAsyncGetServByPort'
            #
            \(\d+\) \s* : \s*
            (?:
                \Qsee previous definition of\E
                |
                \Qsee declaration of\E
                |
                \Qcould be '\E
                |
                \Qor       '\E
            )
        )

        |

        (?:
            # MSVC last line from an ambiguous function call
            \Qwhile trying to match the argument list '\E
        )

        |

        (?:
            # GNU assembler errors (when used with -pipe)
            \Q\{standard input\}: Assembler messages:\E
        )

    }xms,

    # Failure to link.
    #
    # Example:
    #   ld: library not found for -lQtMultimediaKit
    #
    # Captures:
    #   linker  -   the linker command (e.g. "ld") (if any)
    #   error   -   text of the error message ("library not found for -lQtMultimediaKit")
    #   lib     -   the relevant library or object (if any)
    #
    linker_fail => qr{
        (?:

            \A

            (?<linker>
                ld              # basename only
                |
                /[^\s]+/ld      # full path
            )

            :
            \s

            (?<error>
                (?:
                    (?:
                        \Qlibrary not found for \E
                        |
                        \Qframework not found \E
                        |
                        \Qcannot find \E
                    )
                    (?<lib>
                        [\-\w]+
                    )
                )

                |

                \Qsymbol(s) not found\E

                |

                \Qduplicate symbol\E .*

                # add others as discovered
            )

            \z
        )

        |

        (?:
            # `Undefined symbols' error message doesn't contain the linker name
            # in the error message.  Therefore, there is a risk of false positives
            # here (considered acceptable).
            #
            # Whole block of text looks like this, the lines after "Undefined symbols"
            # can be caught by linker_fail_continuation:
            #
            #  Undefined symbols:
            #   "v8::internal::NativesCollection<(v8::internal::NativeType)0>::GetScriptSource(int)", referenced from:
            #       v8::internal::Bootstrapper::NativesSourceLookup(int)  in bootstrapper.o
            #       v8::internal::Bootstrapper::NativesSourceLookup(int)  in bootstrapper.o
            #       v8::internal::Deserializer::ReadChunk(v8::internal::Object**, v8::internal::Object**, int, unsigned char*)in serialize.o
            #
            \A
            \s{0,20}
            (?<error>
                \QUndefined symbols\E

                # mac-only: `for architecture (foo)' might appear when linking
                # a bundle with multiple architectures
                (?: \Q for architecture \E [^:]+ )?

                :
            )
            \s{0,20}
            \z
        )

        |

        (?:
            # Linux-style undefined or multiply defined symbol, e.g.
            #  tst_sphere.o: In function `tst_Sphere::planes() const':
            #  tst_sphere.cpp:(.text+0x244): undefined reference to `ViewportCamera::ViewportCamera()'
            #  tst_sphere.o:tst_sphere.cpp:(.text+0x3bb): more undefined references to `Frustum::plane(QFlags<Frustum::Plane>) const' follow
            \A
            \s{0,20}

            .+?     # file part (may be .o, .cpp, or both, with also .text reference)

            :
            \s

            (?:
                \Qundefined reference to `\E
                |
                \Qmore undefined references to `\E
                |
                \Qmultiple definition of `\E
            )

            .+
            \z
        )

        |

        (?:
            # Windows:
            # ..\..\lib\QtWidgets5.dll : fatal error LNK1120: 1 unresolved externals
            \A
            \s{0,20}

            (?<lib>
                [^:]+?
            )

            \s+
            :
            \s+

            (?<error>
                \Qfatal error LNK\E \d+:
                \s+
                \d+
                \s+
                unresolved externals
            )

        )

        |

        (?:
            # Windows:
            # qfiledialog_win.obj : error LNK2019: unresolved external symbol "char const * const qt_file_dialog_filter_reg_exp" (?qt_file_dialog_filter_reg_exp@@3PBDB) referenced in function "class QString __cdecl qt_win_extract_filter(class QString const &)" (?qt_win_extract_filter@@YA?AVQString@@ABV1@@Z)
            (?<error>
                (?:fatal\s)?
                error\sLNK\d+
            )
        )
    }xms,

    # Line continuing a linker error message previously extracted.
    #
    # For example, in this whole block of text:
    #  Undefined symbols:
    #   "v8::internal::NativesCollection<(v8::internal::NativeType)0>::GetScriptSource(int)", referenced from:
    #       v8::internal::Bootstrapper::NativesSourceLookup(int)  in bootstrapper.o
    #       v8::internal::Bootstrapper::NativesSourceLookup(int)  in bootstrapper.o
    #       v8::internal::Deserializer::ReadChunk(v8::internal::Object**, v8::internal::Object**, int, unsigned char*)in serialize.o
    #
    # ... the lines following `Undefined symbols' can be extracted by this pattern.
    #
    # Captures: nothing
    #
    # Caveats:
    #   Like the similar compile_fail_continuation, has false positives,
    #   so it should only be used in a narrow context (if you already "know" the
    #   line has a high chance of being related to linker errors).
    #
    linker_fail_continuation => qr{
        (?:
            \Q, referenced from:\E
        )

        |

        (?:
            in [ ] [^ ]+\.o\b   # referring to a particular foo.o file
        )

        |

        (?:
            # if there are really a lot of undefined symbols, ld may
            # print a line with only `...' to indicate truncation
            \A \s* \.{3} \s* \z
        )

        |

        (?:
            # referring to a particular function in a .o file, e.g.
            #  tst_sphere.o: In function `tst_Sphere::planes() const':
            \A
            \s*

            [^:]+\.o:
            \s
            \QIn function `\E

            .+
            \z
        )

        |

        (?:
            # referring to the first place a symbol was defined when
            # failing with a "multiple definition of ..." error
            \Q: first defined here\E
        )


        # add others as discovered
    }xms,

    # Line indicating a library is being linked.
    # This is used to keep track of which libraries have been built, to
    # give extra information in the case of errors relating to libraries.
    #
    # Examples:
    #   g++ (...) -o libQtMultimediaKit.so.5.0.0
    #   linking ../../lib/libQtCore.so.5.0.0
    #
    # Captures:
    #   lib     -   the library name (exactly as printed - i.e. may or may
    #               not be absolute, relative, basename ...)
    #
    # Caveats:
    #   This pattern is fairly narrow in scope and won't match all cases.
    #   This is considered acceptable as long as the info is only used
    #   to provide additional hints.  In other words, if this pattern
    #   matches, you can be fairly sure that a library was built; if it
    #   doesn't match, you shouldn't assume the library wasn't built.
    #
    linked_lib  =>  qr{
        \A

        (?:
            # non-silent mode, with gcc
            (?: gcc | g\+\+ )
            .+

            -o
            \s

            (?<lib>
                lib [^\.]+ \. # name always starts with libSomething.

                (?:
                    so        # linux: libQtCore.so.5.0.0
                    |
                    \d        # mac:   libQtCore.5.0.0.dylib
                )

                [^\s]+
            )
        )

        |

        (?:
            # non-silent mode, static lib (ar)
            # command is usually like: ar cqs libFoo.a
            ar
            \s+
            [cqs]+
            \s+

            (?<lib>
                lib [^\.]+ \.a
            )
            \s+
            # ... then the list of .o files, which we don't care about.
        )

        |

        (?:
            # silent mode, linking path/to/libWhatever.so
            linking

            \s

            (?<lib>
                [^\s]+

                (?:
                    \.so
                    |
                    \.dylib     # must contain at least one .so or .dylib to be a library
                )

                [^\s]+
            )

            \z
        )

        |

        (?:
            # silent mode, linking path/to/Something.framework/Something
            linking

            \s

            [^\s]+?
            /
            (?<lib>
                \w+
                \.
                framework
            )
            /

            [^\s]+

            \z
        )
    }xms,

    # qmake failed to parse a .pro file.
    #
    # Examples:
    #
    # /home/qt/.pulse2-agent/data/recipes/133472730/base/qt/qtmultimediakit/src/imports/multimedia/multimedia.pro:28: Parse Error ('qdeclarativecamera_p.h qdeclarativecameracapture_p.h qdeclarativecamerarecorder_p.h qdeclarativecameraexposure_p.h qdeclarativecameraflash_p.h qdeclarativecamerafocus_p.h qdeclarativecameraimageprocessing_p.h qdeclarativecamerapreviewprovider_p.h')
    # Error processing project file: /home/qt/.pulse2-agent/data/recipes/133472730/base/qt/qtmultimediakit/src/imports/multimedia/multimedia.pro
    #
    # Captures:
    #   file    -   the file in which the error was encountered
    #
    # Caveats:
    #   This pattern assumes files containing qmake script are always named
    #   ending with .pri, .prf or .pro.  This is purely a convention and is
    #   not enforced anywhere.  The pattern will miss things if people start
    #   to violate this convention.
    #
    qmake_fail => qr{
        (?:
            \A

            # path/to/file.pro:123: Parse Error
            (?<file>
                [^:]+?
                \.pr[iof]
            )
            :\d+:
            \s*
            \QParse Error\E
            .*
            \z
        )

        |

        (?:
            \A
            (?:
                \QError processing project file: \E
                |
                \QCannot find file: \E
            )
            (?<file>
                [^:]+?
                \.pr[iof]
            )
            \.?
            \z
        )

        # add more as discovered
    }xms,


    # Info about some pulse property.
    #
    # Note that these lines come from our pulseconfig/test.pl script,
    # and not from Pulse itself.  Pulse itself does not put the values
    # of properties directly into the build logs.
    #
    # Example:
    #
    #  PULSE_STAGE='linux-g++-32 Ubuntu 10.04 x86'
    #
    # Captures:
    #   property    -   the property name (all in uppercase and _ instead of .,
    #                   e.g. QT_TESTS_ENABLED rather than qt.tests.enabled)
    #   value       -   the value of the property
    #
    pulse_property => qr{
        \A

        # Windows-only starts with cmd-style `set '
        (?: set \s )?

        PULSE_

        (?<property>
            [^=]+
        )

        =

        # value may or may not be quoted
        (?:
            '
            (?<value>
                [^']+
            )
            '

            |

            (?<value>
                [^'].+
            )
        )

        \z
    }xms,

    # If matched, indicates that all failures prior to this point in the log are non-fatal.
    # Usually the reason for this is that a part of the test script is configured to treat
    # errors as warnings.
    #
    # Example:
    #  Normally I would now fail.  However, `forcesuccess' was set in C:/test/recipes/129373577/base/_pulseconfig/projects/Qt_Modules_Continuous_Integration/stages/win32-msvc2010_Windows_7/forcesuccess.
    #
    # Captures: nothing
    #
    forget_errors => qr{
        \A
        (?:
            # forcesuccess set in testconfig
            \QNormally I would now fail.  However, `forcesuccess' was set\E

            |

            # some foo.insignificant=1 property was set, to treat errors as warnings
            \QThis is a warning, not an error, because\E
        )
    }xms,

    # The line where execution of an autotest begins.
    #
    # Example (old style):
    #   make[3]: Entering directory `/home/qt/.pulse2-agent/data/recipes/129375783/base/qt/qtsystems/tests/auto/common'
    #   /home/qt/.pulse2-agent/data/recipes/129371992/base/_qtqa_latest/scripts/generic/testrunner.pl --timeout 900 --tee-logs /home/qt/.pulse2-agent/data/recipes/129371992/base/_artifacts/test-logs --plugin core --plugin flaky -- ./tst_qhostinfo
    #
    # Example (new style):
    #   QtQA::App::TestRunner: begin tst_qmdiarea: [./tst_qmdiarea.app/Contents/MacOS/tst_qmdiarea] [-silent] [-o] [/Users/qt/.pulse2-agent/data/recipes/179090167/base/_artifacts/test-logs/tst_qmdiarea-testresults-00.xml,xml] [-o] [-,txt]
    #
    # Captures:
    #   name    -   human-readable autotest name
    #
    # Caveats:
    #   The old style depends on usage of testrunner.pl or special output from make,
    #   and is a little prone to error.
    #   The new style should be robust when testscheduler is used.
    #
    autotest_begin => qr{
        \A

        (?:
            # new style, testscheduler
            QtQA::App::TestRunner:\ begin
            [ ]

            (?:
                # can be a command ...
                \[

                # consume all up to the last \ or /, if any, so that 'name' contains
                # only the basename.
                (?:
                    [^\]]{1,100}
                    (?:/|\\)
                )?

                (?<name>
                    [^\]]{1,100}
                )
                \]

                |

                # or it can be a human-readable label
                (?<name>
                    [^:]{1,200}
                )
                :[ ]
            )

        )

        |

        (?:
            # old style

            .*?
            (?:
                scripts[/\\]generic[/\\]testrunner\.pl
                |
                bin[/\\]testrunner(?:\.bat)?
            )

            .*?         # all the arguments to testrunner.pl
            [ ]--[ ]    # end of the arguments to testrunner.pl
            [^\s]+?     # path up to the last directory separator
            [/\\]       # the last directory separator
            (?<name>
                [^\s]+  # basename of the test
            )
        )

        |

        (?:
            # if testrunner is not used, the best we can do is to see when `make'
            # says it is entering a directory

            [gn]?make
            \[ \d+ \]
            :
            \s
            Entering[ ]directory[ ]

            `
            [^']+?                  # path up to the last /
            /                       # last /
            (?<name>
                [^/']+              # name of directory containing test
            )
            '
        )
    }xms,

    # The line where execution of an autotest ends.
    #
    # Example:
    #   QtQA::App::TestRunner: end tst_qmdiarea, 5 seconds, exit code 0
    #
    # Captures:
    #   name    -   human-readable autotest name
    #
    autotest_end => qr{
        \A

        QtQA::App::TestRunner:\ end
        [ ]

        (?<name>
            [^:]{1,200}
        )
        :
        [ ]
    }xms,

    # Indicator that an autotest failed.
    #
    # Captures:
    #   name    -   autotest's human-readable name
    #
    autotest_fail => qr{
        \A
        QtQA::App::TestScheduler:\ (?<name>.{1,200})\ failed

        # "run concurrently with" appears on parallel tests only
        (?:
            ;\ run\ concurrently\ with\ .*
        )?

        \z
    }xms,

    # Indicator that an autotest was flaky.
    #
    autotest_flaky => qr{
        \A
        \QQtQA::App::TestRunner: the test seems to be flaky\E
    }xms,

    # The line where a QtQA::TestScript::fatal_error YAML error opens.
    #
    yaml_begin => qr{
        \A
        \Q--- !qtqa.qt-project.org/error\E
        \z
    }xms,

    # The line where a QtQA::TestScript::fatal_error YAML error ends.
    #
    yaml_end => qr{
        \A
        \Q... \E\#\Q end qtqa.qt-project.org/error\E
        \z
    }xms,

    # Generic strerror-based pattern.
    #
    # This pattern will find any line containing an error string commonly returned by strerror()
    # (in English).
    # This is useful for Unix utilities where the convention on error is to perror() and exit.
    #
    # Example:
    #   sh: /Users/qt/python27/bin/rm: No such file or directory
    #
    # Captures: nothing
    #
    # Caveats:
    #   The strings returned by strerror() can be terse, so this pattern may cause some false
    #   positives.  Also, some parts of a build process might be "expected" to produce
    #   some of these error messages.  Therefore it is best to use this pattern only to scan
    #   the lines surrounding some other, more definite error.
    #
    strerror => (sub {
        my @re = map { "\Q$_\E" } @POSIX_ERROR_STRINGS;
        my $re = join('|', @re);
        return qr{\b(?:$re)\b}i;
    })->(),

    # Pattern for lines to be considered insignificant; these lines are both not considered
    # when determining the cause of a failure, and are omitted from the output of the script.
    #
    # This is used to reduce false positives or "expected" errors.
    #
    # Captures: nothing
    #
    insignificant => qr{
        (?:
            # Seemingly harmless and widely ignored warnings from gdb.
            # Some discussion at http://sourceware.org/ml/gdb-patches/2011-05/msg00372.html
            \Qwarning: Can't read pathname for load map: Input/output error.\E
        )

        |

        (?:
            # Removes more insignificant lines from gdb during a crashed autotest.
            # gdb will try to open libc sources when doing a backtrace of abort(), these
            # sources are generally unavailable.
            \Q../nptl/sysdeps/unix/sysv/linux/raise.c: No such file or directory.\E
        )

        |

        (?:
            # nmake's output when a command in a submake fails is devoid of any useful information;
            # in particular it doesn't include any details about which directory we were in when
            # compile failed.  These messages are nothing but noise.
            \QNMAKE : fatal error U1077: \E

            # command is double-quoted if it has spaces
            '"?
            (?:
                # nmake.exe and cd come from recursive nmakes
                .{0,200}
                \\nmake\.exe
                |
                cd
            )
            "?'

            \Q : return code '0x\E
            [0-9a-f]{1,16}
            '
        )

        |

        (?:
            # We deliberately disable "Saved Application State" on mac by denying applications
            # write permission to the relevant directory; unfortunately this generates these
            # spurious warnings.
            \QPersistent UI failed to open file \E.{0,200}/Saved%20Application%20State/.{0,200}\Q: Permission denied\E
        )

        # add more as discovered
    }xms,

    # Pattern for lines to be hidden from output; these lines may be considered when
    # determining the cause of a failure, but they will be omitted from the output of the script.
    #
    # This is used to exclude messages which can be used by this script to identify the
    # reason for a failure, but which provide no useful information to a human attempting to
    # read a failure summary.
    #
    # Captures: nothing
    #
    hidden => qr{
        (?:
            # nmake: testrunner.BAT non-zero exit code is irrelevant, and maybe confusing to some.
            # Only the test itself has relevant output.
            \QNMAKE : fatal error U1077: \E

            # command is double-quoted if it has spaces
            '"?
            .{0,200}
            \\testrunner(?i:\.bat)
            "?'

            \Q : return code '0x\E
            [0-9a-f]{1,16}
            '
        )

        # add more as discovered
    }xms,
);

sub new
{
    my ($class) = @_;

    my $self = bless {}, $class;
    return $self;
}

sub run
{
    my ($self, @args) = @_;

    $self->set_options_from_args( @args );

    my @log_lines = $self->read_file( );

    # We pass through the log twice.
    # The first pass determines what caused the build to fail (if anything) ...
    my $fail = $self->identify_failures(
        lines   =>  \@log_lines,
    );

    if ($self->{ debug }) {
        print STDERR Data::Dumper->Dump([ $fail ], [ 'fail' ]);
    }

    # The second pass extracts and prints the messages which relate to the failure reason.
    $self->extract_and_output(
        lines   =>  \@log_lines,
        fail    =>  $fail,
    );

    return;
}

# Set various parts of $self based on command-line @args.
# Dies if there is a problem.
sub set_options_from_args
{
    my ($self, @args) = @_;

    $self->{ limit_lines } = 1000;

    GetOptionsFromArray( \@args,
        'help'          =>  sub { pod2usage(0) },
        'debug'         =>  \$self->{ debug },
        'summarize'     =>  \$self->{ summarize },
        'limit=i'       =>  \$self->{ limit_lines },
    ) || pod2usage(1);

    # Should be exactly one argument left - the filename.
    if (@args > 1) {
        print STDERR "Too many arguments: @args\n";
        pod2usage(2);
    }
    if (@args < 1) {
        print STDERR "Not enough arguments!  I need the filename of the log to parse.\n";
        pod2usage(2);
    }

    $self->{ file } = shift @args;

    return;
}

# Given a raw log line, returns a normalized form of that line; for example:
#  - strips Pulse-format timestamps
#  - trims trailing whitespace
#
# The purpose of this is to format lines in such a way that regular expressions
# do not need to be written to explicitly handle things which may or may not
# be in the logs; e.g. the Pulse timestamps.
sub normalize_line
{
    my ($self, $line) = @_;

    $line =~ s/$RE{ pulse_timestamp }//;

    # Note: don't use Text::Trim here, it's surprisingly slow.
    $line =~ s/\s+\z//;

    return $line;
}

sub read_file_from_url
{
    my ($self, $url) = @_;

    my $text;

    # Be robust against temporary network disruptions, etc.
    my $i = 1;
    while (1) {
        my $cv = AE::cv();
        my $req = http_request( GET => $url, timeout => 60, sub { $cv->send( @_ ) } );

        my ($data, $headers) = $cv->recv();

        my $status = $headers->{ Status };
        if ($headers->{ Status } == 200) {
            $text = $data;
            last;
        }

        my $reason = $headers->{ Reason };
        my $error = "fetch $url [attempt $i]: $status $reason";

        # Do not retry on timeout error; on others, we do
        if ($reason =~ m{timed out}) {
            die "$error\n";
        }

        if ($i >= 6) {
            # Give up ...
            die "fetch $url repeatedly failed in $i attempts.\n  Last error: $error\n";
        }

        ++$i;

        # Try again soon
        my $delay = 2**($i-1);
        warn "$error\n  Trying again in $delay seconds...\n";
        sleep $delay;
    }

    return $text;
}

sub read_file
{
    my ($self) = @_;

    my $file = $self->{ file };

    my $text;
    my @lines;

    if ($file =~ m{://} && ! -e $file) {
        # We've guessed that the user passed a URL
        # (note it is technically possible to have a file named e.g.
        # http://example.com/foo.html on local disk).
        $text = $self->read_file_from_url( $file );
    }
    else {
        # normal read from disk
        $text = File::Slurp::read_file( $file );
    }

    my $uncompressed;

    # Allow compressed or uncompressed logs.
    # anyinflate autodetects compression if it is supported and writes uncompressed
    # content to $uncompressed. If not compressed or compression not detected
    # $uncompressed includes original content when scalar reference is used
    if (! anyinflate( \$text => \$uncompressed )) {
        die "Failed to process: $file\nerror: $AnyInflateError\n";
    }

    @lines = split( qr{\n}, $uncompressed );

    # normalize before returning
    @lines = map { $self->normalize_line($_) } @lines;

    return @lines;
}

# Truncates lines exceeding $MAX_LINE_LENGTH to $MAX_LINE_LENGTH
sub ensure_line_length
{
    my ($self, $line) = @_;

    # The max amount of characters permitted in a line;
    # any more than this and we will truncate the line.
    # Longer lines could trigger bad performance in some regexes, and it is
    # not user-friendly to present such long lines to the reader.
    Readonly my $MAX_LINE_LENGTH => 3500;

    my $length = length($$line);
    if ($length > $MAX_LINE_LENGTH) {
        my $truncated = " (truncated)";
        $$line = substr($$line, 0, $MAX_LINE_LENGTH - length($truncated) ) . $truncated;
        if ($self->{ debug }) {
            print STDERR "line too long ($length characters), truncated to " . length($$line) . " characters\n";
        }
    }
    return;
}

# Create a handler for identifying "chunks" of text.
# A chunk may be, for example, the autoput from a single autotest.
#
# First parameter is the chunk name.
# Second parameter is a hash with keys:
#
#   begin_re:   regular expression to match beginning of chunk (i.e. to terminate
#               processing of the chunk)
#   begin_sub:  callback when begin_re is matched.  May return 0 to continue
#               processing, 1 if processing should terminate.
#   giveup_sub: callback when too many lines have been read, and processing is
#               about to terminate
#   read_sub:   callback when reading each line (optional; if unset, defaults to
#               appending the current line to the chunk details)
#
# All above callbacks will receive a chunk hashref, the current line, and an out
# hashref to hold failure information.
#
# Returns a callback which should be passed a line and an out hashref (passed to
# the inner callbacks).
#
# The callback returns 1 iff the chunk has completed.
#
sub chunk_handler
{
    my ($self, $name, %chunk) = @_;

    $chunk{ details } ||= q{};
    $chunk{ _chunk_name } = $name;

    return sub {
        my ($line, $out) = @_;
        return $self->_handle_chunk_line( \%chunk, $line, $out );
    };
}

# Handle a single $line for the given $chunk.
# $chunk, $line and $out are all passed to the begin/giveup/read callbacks.
# This function is an implementation detail of chunk_handler and does not
# make sense to call from elsewhere.
sub _handle_chunk_line
{
    my ($self, $chunk, $line, $out) = @_;

    my $name = $chunk->{ _chunk_name };
    my $length = length($line);

    # are we done?
    if ($line =~ $chunk->{ begin_re }) {
        if ($chunk->{ begin_sub }->( $chunk, $line, $out )) {
            return 1;
        }
    }

    # no, we're not done.
    # shall we give up?
    if (++$chunk->{ lines } > $MAX_CHUNK_LINES) {
        if ($self->{ debug }) {
            print STDERR "giving up on reading `$name' details, too many lines.\n";
        }
        if ($chunk->{ giveup_sub }) {
            $chunk->{ giveup_sub }->( $chunk, $line, $out );
        }
        return 1;
    }

    # no, we're not giving up.

    if ($chunk->{ read_sub }) {
        $chunk->{ read_sub }->( $chunk, $line, $out );
    } else {
        $chunk->{ details } = "$line\n" . $chunk->{ details };
    }

    return;
}

# Create a handler for an autotest output chunk.
sub autotest_chunk_handler
{
    my ($self, %chunk) = @_;

    $chunk{ begin_re } = $RE{ autotest_begin };

    # Called when first line of autotest output is found;
    # terminates the chunk handler (if it is the right autotest).
    $chunk{ begin_sub } = sub {
        my ($chunk_ref, $line, $out) = @_;

        my $name = $+{ name };
        $name =~ s{\.exe$}{}i; # don't care about trailing .exe, if any

        # If $name matches our name, we definitely found the test now,
        # even if we couldn't find the end of the test in autotest_end.
        $chunk_ref->{ found_test } ||= ($name eq $chunk_ref->{ name });

        # We have not completed if we didn't yet find the right test.
        if (!$chunk_ref->{ found_test }) {
            # Start gathering output again from nothing at each test boundary.
            # The first seen details are retained as a fallback.
            $chunk_ref->{ first_details } ||= $chunk_ref->{ details };
            $chunk_ref->{ details } = q{};
            return;
        }

        push @{$out->{ autotest_fail }}, {
            name    =>  $name,
            details =>  $chunk_ref->{ details },
            flaky   =>  $chunk_ref->{ flaky },
        };
        return 1;
    };


    # Called when we're giving up.  When this occurs, we might fall back
    # and say that an unknown autotest failed.
    $chunk{ giveup_sub } = sub {
        my ($chunk_ref, $line, $out) = @_;

        my $name = $chunk_ref->{ name } || '(unknown autotest)';

        push @{$out->{ autotest_fail }}, {
            name    =>  $name,
            details =>  $chunk_ref->{ first_details } || q{},
        };
    };


    # Called on each line.  Gathers the test output and decides if the test
    # was flagged as flaky.
    $chunk{ read_sub } = sub {
        my ($chunk_ref, $line, $out) = @_;
        if ($line =~ $RE{ autotest_flaky }) {
            $chunk_ref->{ flaky } = $line;
        }

        # Look for an autotest end line specifically matching this test.
        if (
            !$chunk_ref->{ found_test }
                && $line =~ $RE{ autotest_end }
                && $+{ name } eq $chunk_ref->{ name }
        ) {
            $chunk_ref->{ found_test } = 1;
            # Everything we read up to now was no good, throw it away and start again.
            $chunk_ref->{ details } = q{};
            $chunk_ref->{ first_details } = q{};
        }

        $chunk_ref->{ details } = "$line\n" . $chunk_ref->{ details };
    };

    return $self->chunk_handler( 'autotest', %chunk );
}

# Create a handler for an embedded YAML chunk.
sub yaml_chunk_handler
{
    my ($self, %chunk) = @_;

    $chunk{ begin_re } = $RE{ yaml_begin };

    $chunk{ begin_sub } = sub {
        my ($chunk_ref, $line, $out) = @_;
        my $text = "$line\n" . $chunk_ref->{ details };
        my $loaded = eval { YAML::Load( $text ) };
        if ($loaded) {
            push @{$out->{ yaml_fail }}, $loaded;
        } else {
            warn "log seems to contain a corrupt YAML block:\n$text\nFailed to parse: $@";
        }
    };

    return $self->chunk_handler( 'yaml', %chunk );
}

sub identify_failures
{
    my ($self, %args) = @_;

    my $out = {};

    # If 0, we should not care about any more failures we see.
    my $save_failures = 1;

    my $chunk_handler;

    # We are trying to identify the reasons why this build failed.
    # We start from the end of the log and move backwards, since we're interested in what caused
    # the build to terminate.
    foreach my $line (reverse @{$args{ lines }}) {

        $self->ensure_line_length(\$line);

        if ($chunk_handler) {
            if ($chunk_handler->( $line, $out )) {
                undef $chunk_handler;
            }
            next;
        }

        # ignore insignificant lines
        next if ($line =~ $RE{ insignificant });

        # qtqa script failed?
        #
        # It's useful to save the name of the script which we were running,
        # to customize the output in some cases.
        #
        if ($save_failures && $line =~ $RE{ qtqa_script_fail }) {
            $out->{ qtqa_script }      = $+{ qtqa_script };
            $out->{ qtqa_script_fail } = $line;
        }

        # make tool failed?
        #
        if ($save_failures && $line =~ $RE{ make_fail }) {
            $out->{ make_fail } = $line;

            my $target = $+{ target };
            my $errortext = $+{ errortext };
            my $errorlevel = $+{ errorlevel };

            # If we're running qtmod_test.pl, try to determine specifically which module
            # failed to compile
            if ($out->{ qtqa_script } && $out->{ qtqa_script } =~ m{qtmod_test\.pl}i) {
                if ($target && $target =~ m{\A module-(q[^\-]+)}xms) {
                    $out->{ qtmodule } = $1;
                }
            }

            if ($target && $target eq 'check'
             || $errortext && $errortext =~ m{testrunner(?:\.bat)\b.*return code}i) {
                $out->{ make_check_fail } = $line;

                # start reading the details of the failure.
                $chunk_handler = $self->autotest_chunk_handler( found_test => 1 );
            }

            $out->{ significant_lines }{ $line } = 1;
        }

        # autotest failed?
        elsif ($save_failures && $line =~ $RE{ autotest_fail }) {
            $chunk_handler = $self->autotest_chunk_handler(
                name => $+{ name },
                # If we don't know the name, we have no way to correctly identify the
                # test, so just assume we've found it already.
                found_test => $+{ name } ? 0 : 1,
            );
        }

        # opening a YAML error message?
        elsif ($save_failures && $line =~ $RE{ yaml_end }) {
            $chunk_handler = $self->yaml_chunk_handler( );
        }

        # compiler failed?
        #
        elsif ($save_failures && $line =~ $RE{ compile_fail }) {
            $out->{ compile_fail }                       = $line;

            if ($+{ file }) {
                $out->{ compile_fail_sources }{ $+{ file } } = $line
            }

            if ($out->{ qtmodule }) {
                $out->{ compile_fail_qtmodule } = $out->{ qtmodule };
            }

            $out->{ significant_lines }{ $line } = 1;
        }

        # linking failed?
        #
        elsif ($save_failures && $line =~ $RE{ linker_fail }) {
            my $lib = $+{ lib };

            $out->{ linker_fail } = $line;

            if ($out->{ qtmodule }) {
                $out->{ linker_fail_qtmodule } = $out->{ qtmodule };
            }

            if ($lib) {
                $out->{ linker_fail_lib }{ $lib } = $line;

                # Did the linker refer to a library which was created _later_ in the build?
                # (remember that we're parsing the log backwards)
                $lib =~ s{\A-l}{lib};  # -lQtCore -> libQtCore

                my $linked_lib = $out->{ linked_libs }{ $lib };
                if ($linked_lib) {
                    $out->{ linker_attempted_to_link_too_early }{ $lib } = 1;

                    # Also mark the line doing the linking as "significant" to show that
                    # the lib was linked in the wrong order
                    $out->{ significant_lines }{ $linked_lib } = 1;
                }
            }

            $out->{ significant_lines }{ $line } = 1;
        }

        # linking succeeded?  If so, store the built lib name for future reference
        #
        elsif ($line =~ $RE{ linked_lib }) {
            my ($lib, undef, undef) = fileparse( $+{ lib }, qr{\..+$} );

            $out->{ linked_libs }{ $lib } = $line;
        }

        # qmake failed?
        #
        elsif ($save_failures && $line =~ $RE{ qmake_fail }) {
            $out->{ qmake_fail } = $line;
            $out->{ qmake_fail_sources }{ $+{ file } } = $line;

            if ($out->{ qtmodule }) {
                $out->{ qmake_fail_qtmodule } = $out->{ qtmodule };
            }

            $out->{ significant_lines }{ $line } = 1;
        }

        # Pulse config problem?
        elsif ($save_failures && $line =~ $RE{ pulse_config_error }) {
            $out->{ pulse_config_error } = $line;
            $out->{ significant_lines }{ $line } = 1;
        }

        # Badly understood glitchy behavior?
        elsif ($save_failures && $line =~ $RE{ glitch }) {
            $out->{ glitch } = $line;
            $out->{ significant_lines }{ $line } = 1;
        }

        # Extract some possibly useful info about the pulse properties
        #
        elsif ($line =~ $RE{ pulse_property })
        {
            $out->{ pulse_property }{ $+{ property } } = $+{ value };
        }

        # Something happen to make us ignore errors?
        # (e.g. errors treated as warnings?)
        #
        elsif ($line =~ $RE{ forget_errors })
        {
            # We're parsing the log backwards and we found a message indicating
            # that errors up to this point are not fatal; we keep parsing the
            # rest of the log for additional context, but none of the lines we're
            # parsing can be considered as contributing to the failure.
            $save_failures = 0;
        }
    }

    return $out;
}

sub extract_autotest_fail
{
    my ($self, %args) = @_;

    my $fail = $args{ fail };
    my $indent = $args{ indent };
    my $lines_ref = $args{ lines_ref };

    foreach my $autotest (@{ $fail->{ autotest_fail } || []} ) {
        my @lines = split( /\n/, $autotest->{ details } );
        push @{$lines_ref}, map( { "$indent$_\n" } @lines ), "\n";
    }

    return;
}

sub extract_yaml_fail
{
    my ($self, %args) = @_;

    my $fail = $args{ fail };
    my $indent = $args{ indent };
    my $lines_ref = $args{ lines_ref };

    foreach my $error (@{ $fail->{ yaml_fail } || []} ) {
        my @lines = split( /\n/, $error->{ error } );
        push @{$lines_ref}, map( { "$indent$_\n" } @lines ), "\n";
    }

    return;
}

sub extract_and_output
{
    my ($self, %args) = @_;

    my $fail  = $args{ fail };
    my @lines = @{$args{ lines }};
    my @lines_to_print;

    if (!$fail || ref($fail) ne 'HASH' || !%{$fail}) {
        # No idea about the failure ...
        return;
    }

    # Buffer of recent lines, in case we need to look backwards.
    # Only keeps unprinted lines, and is cleared whenever something is printed.
    #
    # The value selected for $RECENT_MAX has some effects other than memory usage;
    # for example, if a file main.cpp fails to compile, then any previous
    # messages relating to main.cpp will be printed, up to a maximum distance
    # of $RECENT_MAX from the line where the error occurred.
    #
    # This means that increasing $RECENT_MAX increases the chance of false positives,
    # and decreasing it increases the chance of losing some valuable info.
    # The correct value to use is linked somewhat to the `-j' option used in builds
    # (consider: if we compile up to 30 source files simultaneously, then there
    # may be ~30 simultaneously interleaved streams at any one time).
    #
    my @recent = ();
    Readonly my $RECENT_MAX => 60;

    my $indent = q{};
    my @continuation_patterns = ();

    if ($self->{ summarize }) {
        $self->output_summary( $fail );
        $indent = "  ";
    }

    # YAML failures (explicit failure messages from the test script(s)) come first.
    $self->extract_yaml_fail(
        fail => $fail,
        indent => $indent,
        lines_ref => \@lines_to_print,
    );

    # Output any autotest failures next.
    $self->extract_autotest_fail(
        fail => $fail,
        indent => $indent,
        lines_ref => \@lines_to_print,
    );

    # Mark a line as significant and print it.
    #
    # Parameters:
    #  $line           -   the line to consider significant (and print)
    #  @continuations  -   zero or more regular expressions which, if matched,
    #                      will be considered a continuation of this significant
    #                      message (e.g. for compile failures spanning multiple
    #                      lines)
    #
    my $line_is_significant = sub {
        my ($line, @continuations) = @_;
        push @continuation_patterns, @continuations;

        # Before we print this significant line, see if any of the previous lines
        # are significant, according to @continuations.
        foreach my $recent_line (@recent) {
            if ( any { $recent_line =~ $_ } @continuation_patterns ) {
                next if ($recent_line =~ $RE{ insignificant });
                push @lines_to_print, "$indent$recent_line\n";
            }
        }

        push @lines_to_print, "$indent$line\n";
        @recent = ();
    };


    while (@lines) {

        # keep no more than $RECENT_MAX lines in memory.
        while (scalar(@recent) > $RECENT_MAX) {
            shift @recent;
        }

        my $line = shift @lines;
        $self->ensure_line_length(\$line);

        next if ($line =~ $RE{ insignificant } || $line =~ $RE{ hidden });

        # Have we explicitly stored this as a significant line already?
        if ($fail->{ significant_lines }{ $line }) {

            # Compilation failure?
            if ($fail->{ compile_fail } && $line =~ $RE{ compile_fail }) {
                # When extracting any further messages relating to this error, we look for
                # the "generic" continuation patterns ...
                my @continuation_patterns = ($RE{ compile_fail_continuation });

                # ... and, if we could identify the file at fault, we look for messages relating
                # to this specific file.
                if (my $file = $+{ file }) {
                    push @continuation_patterns, qr{(?:\b|\A) \Q$file\E (?:\b|\z)}xms;
                }

                $line_is_significant->( $line, @continuation_patterns );

                next;
            }

            # Linker failure?
            if ($fail->{ linker_fail } && $line =~ $RE{ linker_fail }) {
                $line_is_significant->( $line, $RE{ linker_fail_continuation } );
                next;
            }

            # Any failure for which we might benefit by scanning for generic
            # strerror-like messages?
            if ( $fail->{ make_fail } && $line =~ $RE{ make_fail }
              || $fail->{ glitch} && $line =~ $RE{ glitch }
            ) {
                my @patterns = ($RE{ strerror });

                # if we have a make target, and it looks like it might be referring to
                # a filename, then also find lines referring to that name
                if (my $target = $+{ target }) {
                    if ($target =~ m{/|\\}) {
                        push @patterns, qr{\Q$target\E};
                    }
                }

                $line_is_significant->( $line, @patterns );
                next;
            }

            # No continuations found for this significant line
            $line_is_significant->( $line );
            next;
        }

        #=============== KEEP THIS AT THE END OF THE LOOP =========================================
        #
        # Any continuations of multiple-line error messages?
        #
        if ( any { $line =~ $_ } @continuation_patterns ) {
            $line_is_significant->( $line );
            next;
        }

        # Nope, no error messages in progress.
        @continuation_patterns = ();
        push @recent, $line;
    }

    # OK, we've figured out what we want to print.
    # Cut it down to size (possibly) before printing.
    $self->apply_limit_lines( indent => $indent, lines_ref => \@lines_to_print );
    print @lines_to_print;

    return;
}

sub apply_limit_lines
{
    my ($self, %args) = @_;

    my $indent = $args{ indent };
    my $lines_ref = $args{ lines_ref };

    my $limit = $self->{ limit_lines };
    return if (!$limit || $limit > @{$lines_ref});

    # We don't know which part of the log is most relevant, but it ought to be
    # the beginning or the end, so we cut out the middle.
    my $chunk_count = int($limit/2);
    my $omitted_count = @{$lines_ref} - (2*$chunk_count);

    @{$lines_ref} = (
        @{$lines_ref}[ 0 .. ($chunk_count-2) ], # -1 additional to make up for the 1 added line
        "$indent(... $omitted_count lines omitted; there are too many errors!)\n",
        @{$lines_ref}[ -$chunk_count .. -1 ],
    );

    return;
}

sub output_summary
{
    my ($self, $fail) = @_;

    my $summary;

    # These failure conditions need to be listed in order from lowest
    # to highest precedence.  e.g. if we know that:
    #
    #  - qtmod_test.pl failed, because:
    #    - make failed, because:
    #      - gcc failed on qxyz.cpp
    #
    # ...then we only want to report the gcc failure - the rest is just noise.

    # test script failed and there are no further details;
    # we omit this message, because it will probably only cause confusion.
    # If people see this message, they'll probably conclude that the test
    # script is buggy - actually, we just couldn't extract any interesting
    # information, so we may as well remain silent.
    #
    if (0 && $fail->{ qtqa_script_fail }) {
        $summary = 'The test script '.$fail->{ qtqa_script }.' failed :(';
    }

    if ($fail->{ make_fail }) {
        $summary = q{`make' failed :(};
    }

    if ($fail->{ make_check_fail }) {
        $summary = q{autotests failed :(};
    }

    if ($fail->{ autotest_fail }) {
        my @autotest_fail = @{ $fail->{ autotest_fail } };
        my @flaky         = grep { $_->{ flaky } } @autotest_fail;

        if (@autotest_fail == 1) {
            $summary = q{Autotest `} . $autotest_fail[0]->{ name } . q{' failed};
        }

        elsif (@autotest_fail <= 5) {
            my @fail_names = map { q{`}.$_->{ name }.q{'} } @autotest_fail;
            @fail_names = sort @fail_names;

            my $fail_names_str = WORDLIST( @fail_names );

            # Example: autotests tst_qstring, tst_qwidget and tst_qfiledialog failed
            $summary = "Autotests $fail_names_str failed";
        }

        else {
            # too many to list (the details will still be given in the body)
            $summary = num2en( scalar(@autotest_fail) ) . q{ autotests failed};
        }

        # do we know the stage name?  (i.e. the test configuration)
        if ($fail->{ pulse_property }{ STAGE }) {
            $summary .= " for $fail->{ pulse_property }{ STAGE }";
        }

        $summary .= q{ :(};

        # any flaky tests?
        if (@flaky) {

            $summary .= qq{\n\n};

            my $tests_were;
            if (@autotest_fail == 1) {
                $tests_were = q{The test was};
            }
            elsif (@flaky == @autotest_fail) {
                $tests_were = q{The tests were};
            }
            else {
                $tests_were = q{Some (not all) of the tests were};
            }

            $summary .= qq{$tests_were determined to be flaky, meaning results were not }
                       . q{consistent across multiple runs.  This might make the problem }
                       . q{difficult to reproduce.  Also, flaky failures might or might not be }
                       . q{related to any recent changes in the source code.};
        }
    }

    if ($fail->{ qmake_fail }) {
        my $qmake_fail_qtmodule = $fail->{ qmake_fail_qtmodule };
        my @qmake_fail_sources = keys %{ $fail->{ qmake_fail_sources } // {} };

        # niceify the names, make them relative to the top-level directory.
        my $pulse_base_dir = $fail->{ pulse_property }{ BASE_DIR };
        if ($pulse_base_dir) {
            @qmake_fail_sources = map {
                my $file = $_;
                $file =~ s{^ \Q$pulse_base_dir\E [\\/]* }{}xms;
                $file
            } @qmake_fail_sources;
        }

        my $pl = (scalar(@qmake_fail_sources) != 1);

        my $some_files = $pl ? 'some files'
                       :       $qmake_fail_sources[0];

        $summary = "qmake failed to process $some_files :(";

        if ($qmake_fail_qtmodule) {
            my $tested_qtmodule = $fail->{ pulse_property }{ QT_GITMODULE };
            if ($tested_qtmodule && $qmake_fail_qtmodule ne $tested_qtmodule) {
                $summary .= "\n\nWe were trying to test $tested_qtmodule.  "
                           ."The qmake error(s) occurred in one of the dependencies, "
                           ."$qmake_fail_qtmodule.";
            }
        }
    }

    # In the vernacular, "compile" is generally understood to also include linking.
    # We will treat compilation and linking the same for the purpose of summarizing.
    my $compile_fail
        = $fail->{ compile_fail }
       // $fail->{ linker_fail };
    my $compile_fail_qtmodule
        = $fail->{ compile_fail_qtmodule }
       // $fail->{ linker_fail_qtmodule };

    if ($compile_fail) {
        $summary = q{Compilation failed};

        # do we know the qtmodule in which compilation failed?
        if ($compile_fail_qtmodule) {
            $summary = "$compile_fail_qtmodule failed to compile";
        }

        # do we know the stage name?  (i.e. the test configuration)
        if ($fail->{ pulse_property }{ STAGE }) {
            $summary .= " for $fail->{ pulse_property }{ STAGE }";
        }

        $summary .= ' :(';

        # if this seems to be a dependency of the tested module, and not the module
        # we intended to test, give a hint about it
        if ($compile_fail_qtmodule) {
            my $tested_qtmodule = $fail->{ pulse_property }{ QT_GITMODULE };
            if ($tested_qtmodule && $compile_fail_qtmodule ne $tested_qtmodule) {
                $summary .= "\n\nWe were trying to test $tested_qtmodule.  "
                           ."One of the dependencies, $compile_fail_qtmodule, "
                           ."failed to compile.";
            }
        }

        # Check for the specific case where someone has attempted to link against
        # some library before it has been compiled.
        my $linked_too_early = $fail->{ linker_attempted_to_link_too_early };
        if ($linked_too_early) {
            my @libs = keys %{ $linked_too_early };

            Lingua::EN::Inflect::NUM( scalar(@libs) );

            my $project      = (@libs > 1) ? 'project(s)'   : 'project';
            my $that_lib_was = inflect 'PL(that) PL(library) PL(was)';
            my $lib          = WORDLIST( @libs, { conj => q{and/or} } );

            $summary .= "\n\nIt seems that some $project tried to link against $lib "
                       ."before $that_lib_was built."
                       ."\n\nThis could be caused by some missing dependencies in .pro file(s). "
                       ."If this is indeed the case, the error may be unstable, and will be "
                       ."easier to reproduce with a highly parallelized build.";
        }

        # Mac-specific: check for incorrectly attempting to link against a framework
        my $linker_fail_lib = $fail->{ linker_fail_lib };
        while (my ($lib, $error) = each %{ $linker_fail_lib // {} }) {

            # if we tried to use framework Foo, the corresponding non-framework name is libFoo
            my $linked_nonframework = $fail->{ linked_libs }{"lib$lib"};

            if ($error =~ m{framework not found} && $linked_nonframework) {
                $summary .= "\n\nIt seems that something tried to link against $lib "
                           ."as a framework, but that library was built _not_ as a framework.";
            }
        }
    }

    # Pulse config problem?
    if ($fail->{ pulse_config_error }) {
        $summary = "It seems that there has been some misconfiguration of the Pulse CI tool, "
                  ."or some related CI infrastructure error. "
                  ."This is NOT the fault of the code under test!"
                  ."\n\nPlease contact $CI_CONTACT to resolve this problem.  Meanwhile, it may "
                  ."be worthwhile to attempt the build again.";
    }

    # YAML failure from a test script?
    if ($fail->{ yaml_fail }) {

        # If the test failure has some context (a 'while' stack),
        # use the top thing from the stack as the human-readable description of
        # what we were doing when we failed.
        my @failed_while = map
            { $_->{ 'while' }
                ? $_->{ 'while' }[0]
                : ()
            } @{ $fail->{ yaml_fail } };

        # capitalize first letter:
        #
        #   setting up git repository -> Setting up git repository
        #
        @failed_while = apply { $_ =~ s{^([a-z])}{\u$1} } @failed_while;

        # append "failed :("
        #
        #   Setting up git repository -> Setting up git repository failed :(
        #
        @failed_while = apply { $_ .= " failed :(" } @failed_while;

        if (@failed_while) {
            $summary = join( qq{\n\n}, @failed_while );
        }
    }

    # Badly understood glitchy behavior?
    if ($fail->{ glitch }) {
        $summary = "An unexpected error occurred, most likely due to no fault in the tested "
                  ."code itself :("
                  ."\n\nPlease point $CI_CONTACT towards this problem.  Meanwhile, it may "
                  ."be worthwhile to attempt the build again.";
    }

    if ($summary) {
        # The summary is supposed to be human-readable text (not preformatted).
        # It's nice to wrap it.
        local $Text::Wrap::columns = 72;
        local $Text::Wrap::huge = 'overflow'; # don't break up long paths
        my $wrapped = wrap(q{}, q{}, $summary);

        # wrap can leave trailing whitespace at the end of each line.
        # Those are generally considered "whitespace errors", so strip them.
        $wrapped =~ s{\h+(?=\n)}{}g;

        print $wrapped;

        # Blank lines after summary begin the (indented) body of the raw text
        print "\n\n";
    }

    return;
}

QtQA::App::ParseBuildLog->new( )->run( @ARGV ) if (!caller);

1;
