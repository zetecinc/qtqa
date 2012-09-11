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

package QtQA::App::SummarizeJenkinsBuild;
use strict;
use warnings;

=head1 NAME

summarize-jenkins-build.pl - generate human-readable summary of a result from jenkins

=head1 SYNOPSIS

  # Explain why this build failed...
  $ summarize-jenkins-build.pl --url http://jenkins.example.com/job/QtBase_master_Integration/10018/
  QtBase master Integration #10017: FAILURE

    Autotest `license' failed for linux-g++-32_Ubuntu_10.04_x86 :(

  # Or, from within a Jenkins post-build step:
  $ summarize-jenkins-build.pl --url "$JOB_URL"

Parse a Jenkins build and extract a short summary of the failure reason(s), suitable
for pasting into a gerrit comment.

=head2 OPTIONS

=over

=item --help

Print this help.

=item --url B<URL>

URL of the Jenkins build. This may be an http or https URL, a local file,
or '-' for standard input.

The build data is fetched from Jenkins using the JSON API.
If a file or standard input are used, the input data must be a valid JSON object.

For a multi-configuration build, the URL of the top-level build should be used.
The script will parse the logs from each configuration.

=item --log-base-url B<base>

Base URL of the build logs.

Optional; if set, build logs will be fetched from URLs under this path, instead
of directly from Jenkins. This may be used to support a setup where Jenkins
build logs are volatile, subject to removal without notice, and the logs are
primarily accessed from another server.

The URLs constructed using B<base> are currently not customizable, and always
use the following pattern:

  <base>/<project_name>/build_<five_digit_build_number>/<configuration>/log.txt.gz

If build logs cannot be fetched from this URL for any reason, the logs are parsed
directly from Jenkins. However, any user-visible links will still refer to the
URL passed in this option.

Note that the build status is still fetched directly from Jenkins.

=item --ignore-aborted

If the build was aborted, but contains at least one failed configuration,
ignore all aborted configurations.

In some cases, if a single configuration of a build has failed, it makes sense to
abort the build immediately rather than waiting for the other configurations to
complete.  In this case, this option may be used to ensure this script reports
the failure summary from the failed configuration(s), rather than the default
behavior of simply reporting "ABORTED" for aborted builds.

=item --force-jenkins-host <HOSTNAME>

=item --force-jenkins-port <PORTNUMBER>

When fetching any data from Jenkins, disregard the host and port portion
of Jenkins URLs and use these instead.

This is useful for network setups (e.g. port forwarding) where the Jenkins
host cannot access itself using the outward-facing hostname, or simply to
avoid unnecessary round-trips through a reverse proxy setup.

=item --debug

Print an internal representation of the build to standard error, for debugging
purposes.

=back

=cut

use AnyEvent::HTTP;
use Capture::Tiny qw(capture);
use Data::Dumper;
use File::Spec::Functions;
use FindBin;
use Getopt::Long qw(GetOptionsFromArray);
use IO::File;
use JSON;
use Pod::Usage;
use Readonly;
use URI;

# Jenkins status constants
Readonly my $SUCCESS => 'SUCCESS';
Readonly my $FAILURE => 'FAILURE';
Readonly my $ABORTED => 'ABORTED';

# Build log parser script
Readonly my $PARSE_BUILD_LOG => catfile( $FindBin::Bin, qw(.. generic parse_build_log.pl) );

# Given a Jenkins $url, returns JSON of depth 1 for the object at that URL,
# or dies on error.
sub get_json_from_url
{
    my ($url) = @_;

    $url =~ s{/$}{};
    $url .= '/api/json?depth=1';

    my $cv = AE::cv();
    my $req = http_request( GET => $url, sub { $cv->send( @_ ) } );
    my ($data, $headers) = $cv->recv();

    if ($headers->{ Status } != '200') {
        die "fetch $url: $headers->{ Status } $headers->{ Reason }\n";
    }

    return $data;
}

# Returns a hashref containing all (relevant) build data from the build at $url,
# or dies on error.
# $url may be a full URL, or a local file, or '-' to read from STDIN.
sub get_build_data_from_url
{
    my ($url) = @_;

    my $json;

    my $fh;
    if (-f $url) {
        $fh = IO::File->new( $url, '<' ) || die "open $url for read: $!";
    } elsif ($url eq '-') {
        $fh = \*STDIN;
    }

    if ($fh) {
        local $/ = undef;
        $json = <$fh>;
    } else {
        $json = get_json_from_url( $url )
    }

    return from_json( $json );
}

# Runs parse_build_log.pl through system() for the given $url
sub run_parse_build_log
{
    my ($url) = @_;

    return system( $PARSE_BUILD_LOG, '--summarize', $url );
}

# Returns the output of parse_build_log.pl on the first
# working of the given @url, or warns and returns nothing
# if all URLs are not usable.
sub get_build_summary_from_log_url
{
    my (@url) = @_;

    return unless @url;

    my $stdout;

    while (!$stdout && @url) {
        my $url = shift @url;
        my $stderr;
        my $status;
        ($stdout, $stderr) = capture {
            $status = run_parse_build_log( $url );
        };

        chomp $stdout;

        if ($status != 0) {
            warn "for $url, parse_build_log exited with status $status"
                .($stderr ? ":\n$stderr" : q{})
                ."\n";

            # Output is not trusted if script didn't succeed
            undef $stdout;
        }
    }

    return $stdout;
}

# Given a Jenkins build object, returns one or more links
# to the build logs, in order of preference.
sub get_url_for_build_log
{
    my ($self, $cfg, $log_base_url) = @_;

    my $url = $cfg->{ url };
    return unless $url;

    my @out;

    if ($log_base_url) {
        if ($url =~
            m{
                \A
                .+
                /job/
                (?<job>
                    [^/]+   # job name

                )
                /
                (?:
                    # jenkins sometimes introduces a useless './' into the URLs
                    \./
                )*
                (?:
                    # configuration part is optional;
                    # it is not present if the failure was on the master, for instance.
                    (?<cfg>
                        [^/]+
                    )
                    /
                )?
                (?<build>
                    [0-9]+
                )
                /?
                \z
            }xms
        ) {
            my ($job_name, $cfg_name, $build_number) = @+{ 'job', 'cfg', 'build' };
            if ($cfg_name) {
                # If $cfg_name only has one axis (the normal case), just use it directly,
                # to avoid useless 'cfg=' in URLs.
                $cfg_name =~ s{\A [^=]+ = ([^=]+) \z}{$1}xms;
                $cfg_name =~ s{ }{_}g;
            }
            push @out, sprintf( '%s/%s/build_%05d%s/log.txt.gz', $log_base_url, $job_name, $build_number, $cfg_name ? "/$cfg_name" : q{});
        } else {
            warn "URL '$url' not of expected format, cannot rebase to $log_base_url\n";
        }
    }

    # Use direct Jenkins logs
    if ($url !~ m{/\z}) {
        $url .= '/';
    }

    push @out, $self->maybe_rewrite_url( $url . 'consoleText' );
    return @out;
}

# Returns a version of $url possibly with the host and port replaced, according
# to the --force-jenkins-host and --force-jenkins-port command-line arguments.
sub maybe_rewrite_url
{
    my ($self, $url) = @_;

    if (!$self->{ force_jenkins_host } && !$self->{ force_jenkins_port }) {
        return $url;
    }

    my $parsed = URI->new( $url );
    if ($self->{ force_jenkins_host }) {
        $parsed->host( $self->{ force_jenkins_host } );
    }
    if ($self->{ force_jenkins_port }) {
        $parsed->port( $self->{ force_jenkins_port } );
    }

    return $parsed->as_string();
}

# Given a jenkins build $url, returns a human-readable summary of
# the build result.
#
# If $log_base_url is set, log URLs are derived under that base
# URL using a predefined pattern, with Jenkins logs used as a fallback.
# Otherwise, the logs are used directly from Jenkins.
sub summarize_jenkins_build
{
    my ($self, $url, $log_base_url) = @_;

    $url = $self->maybe_rewrite_url( $url );

    my $build = get_build_data_from_url( $url );

    if ($self->{ debug }) {
        warn "debug: build information:\n" . Dumper( $build );
    }

    my $result = $build->{ result };
    my $number = $build->{ number };

    my $out = "$build->{ fullDisplayName }: $result";

    if ($result eq $SUCCESS || (!$self->{ ignore_aborted } && $result eq $ABORTED)) {
        # no more info required
        return $out;
    }

    my @configurations = @{$build->{ runs } || []};

    # Only care about runs for this build...
    @configurations = grep { $_->{ number } == $number } @configurations;

    # ...and only care about failed runs.
    # If the top-level build is aborted, the results of individual configurations
    # are not trustworthy.
    @configurations = grep { $_->{ result } eq $FAILURE } @configurations;

    # Configurations are sorted by display name (for predictable output order)
    @configurations = sort { $a->{ fullDisplayName } cmp $b->{ fullDisplayName } } @configurations;

    # If there are no failing sub-configurations, the failure must come from the
    # master configuration (for example, git checkout failed and no builds could
    # be spawned), so we'll summarize that one.
    if (!@configurations) {
        push @configurations, $build;
    }

    my @summaries;

    foreach my $cfg (@configurations) {
        my (@log_url) = $self->get_url_for_build_log( $cfg, $log_base_url );

        my $this_out;

        if (my $summary = get_build_summary_from_log_url( @log_url )) {
            # If we can get a sensible summary, just do that.
            # The summary should already mention the tested configuration.
            $this_out = $summary;
        } else {
            # Otherwise, we don't know what happened, so just mention the
            # jenkins result string.
            $this_out = "$cfg->{ fullDisplayName }: $cfg->{ result }";
        }

        if (@log_url) {
            if ($this_out !~ m{\n\z}ms) {
                $this_out .= "\n";
            }
            $this_out .= "  Build log: $log_url[0]";
        }

        push @summaries, $this_out;
    }

    return join( "\n\n--\n\n", @summaries );
}

sub new
{
    my ($class) = @_;
    return bless {}, $class;
}

sub run
{
    my ($self, @args) = @_;

    my $url;
    my $log_base_url;

    GetOptionsFromArray(
        \@args,
        'url=s' => \$url,
        'log-base-url=s' => \$log_base_url,
        'force-jenkins-host=s' => \$self->{ force_jenkins_host },
        'force-jenkins-port=i' => \$self->{ force_jenkins_port },
        'ignore-aborted' => \$self->{ ignore_aborted },
        'h|help' => sub { pod2usage( 2 ) },
        'debug' => \$self->{ debug },
    );

    $url || die 'Missing mandatory --url option';

    print $self->summarize_jenkins_build( $url, $log_base_url ) . "\n";

    return;
}

__PACKAGE__->new( )->run( @ARGV ) unless caller;
1;
