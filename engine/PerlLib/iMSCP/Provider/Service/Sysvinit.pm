=head1 NAME

 iMSCP::Provider::Service::Sysvinit - Base service provider for `sysvinit' scripts

=cut

# i-MSCP - internet Multi Server Control Panel
# Copyright (C) 2010-2018 by Laurent Declercq <l.declercq@nuxwin.com>
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

package iMSCP::Provider::Service::Sysvinit;

use strict;
use warnings;
use Carp qw/ croak /;
use File::Spec;
use iMSCP::Boolean;
use iMSCP::Debug qw/ debug getMessageByType /;
use iMSCP::Execute qw/ execute /;
use iMSCP::File;
use iMSCP::LsbRelease;
use parent qw/ Common::SingletonClass iMSCP::Provider::Service::Interface /;

my $EXEC_OUTPUT;

=head1 DESCRIPTION

 SysVinit base service provider implementation.

=head1 PUBLIC METHODS

=over 4

=item remove( $service )

 See iMSCP::Provider::Service::Interface

=cut

sub remove
{
    my ( $self, $service ) = @_;

    defined $service or croak( 'Missing or undefined $service parameter' );

    my $initScriptPath = eval { $self->getInitScriptPath( $service, 'nocache' ) } or return;

    debug( sprintf( "Removing the %s sysvinit script", $initScriptPath ));
    iMSCP::File->new( filename => $initScriptPath )->delFile() == 0 or croak(
        getMessageByType( 'error', { amount => 1, remove => TRUE } ) || 'Unknown error'
    );
}

=item start( $service )

 See iMSCP::Provider::Service::Interface

=cut

sub start
{
    my ( $self, $service ) = @_;

    defined $service or croak( 'Missing or undefined $service parameter' );

    return if $self->isRunning( $service );

    $self->_exec( [ $self->getInitScriptPath( $service ), 'start' ] );
}

=item stop( $service )

 See iMSCP::Provider::Service::Interface

=cut

sub stop
{
    my ( $self, $service ) = @_;

    defined $service or croak( 'Missing or undefined $service parameter' );

    return unless $self->isRunning( $service );

    $self->_exec( [ $self->getInitScriptPath( $service ), 'stop' ] );
}

=item restart( $service )

 See iMSCP::Provider::Service::Interface

=cut

sub restart
{
    my ( $self, $service ) = @_;

    defined $service or croak( 'Missing or undefined $service parameter' );

    if ( $self->isRunning( $service ) ) {
        $self->_exec( [ $self->getInitScriptPath( $service ), 'restart' ] );
        return;
    }

    # Service is not running yet, we start it instead
    $self->_exec( [ $self->getInitScriptPath( $service ), 'start' ] );
}

=item reload( $service )

 See iMSCP::Provider::Service::Interface

=cut

sub reload
{
    my ( $self, $service ) = @_;

    defined $service or croak( 'Missing or undefined $service parameter' );

    if ( $self->isRunning( $service ) ) {
        # We need catch STDERR here as we do do want croak on failure
        my $ret = $self->_exec( [ $self->getInitScriptPath( $service ), 'reload' ], undef, \my $stderr );

        # If the reload action failed, we try a restart instead. This cover
        # case where the reload action is not supported.
        $self->restart( $service ) if $ret;
        return;
    }

    # Service is not running yet, we start it instead
    $self->_exec( [ $self->getInitScriptPath( $service ), 'start' ] );
}

=item isRunning( $service )

 See iMSCP::Provider::Service::Interface

=cut

sub isRunning
{
    my ( $self, $service ) = @_;

    defined $service or croak( 'Missing or undefined $service parameter' );

    unless ( defined $self->{'_pid_pattern'} ) {
        # We need to catch STDERR here as we do not croak on failure when command
        # status is other than 0 but no STDERR
        my $ret = $self->_exec( [ $self->getInitScriptPath( $service ), 'status' ], undef, \my $stderr );
        croak( $stderr ) if $ret && length $stderr;
        return $ret == 0;
    }

    my $ret = $self->_getPid( $self->{'_pid_pattern'} );
    undef $self->{'_pid_pattern'};
    $ret;
}

=item hasService( $service [, 'nocache' = FALSE ] )

 See iMSCP::Provider::Service::Interface

=cut

sub hasService
{
    my ( $self, $service, $nocache ) = @_;

    defined $service or croak( 'Missing or undefined $service parameter' );

    eval { $self->_searchInitScript( $service, $nocache ); };
}

=item getInitScriptPath( $service, [ $nocache =  FALSE ] )

 Get full path of the SysVinit script that belongs to the given service

 Param string $service Service name
 Param bool $nocache OPTIONAL If true, no cache will be used
 Return string Init script path on success, croak if the SysVinit script path is not found

=cut

sub getInitScriptPath
{
    my ( $self, $service, $nocache ) = @_;

    defined $service or croak( 'Missing or undefined $service parameter' );

    $self->_searchInitScript( $service, $nocache );
}

=item setPidPattern( $pattern )

 Set PID pattern for next _getPid( ) invocation

 Param string|Regexp $pattern Process PID pattern
 Return void

=cut

sub setPidPattern
{
    my ( $self, $pattern ) = @_;

    defined $pattern or croak( 'Missing or undefined $pattern parameter' );

    $self->{'_pid_pattern'} = ref $pattern eq 'Regexp' ? $pattern : qr/$pattern/;
}

=back

=head1 PRIVATE METHODS

=over 4

=item _init( )

 Initialize instance

 Return iMSCP::Provider::Service::Sysvinit, croak on failure

=cut

sub _init
{
    my ( $self ) = @_;

    my $distID = iMSCP::LsbRelease->getInstance()->getId( 'short' );

    if ( $distID =~ /^(?:FreeBSD|DragonFly)$/ ) {
        $distID = [ '/etc/rc.d', '/usr/local/etc/rc.d' ];
    } elsif ( $distID eq 'HP-UX' ) {
        $distID = [ '/sbin/init.d' ];
    } elsif ( $distID eq 'Archlinux' ) {
        $self->{'sysvinitscriptpaths'} = [ '/etc/rc.d' ];
    } else {
        $self->{'sysvinitscriptpaths'} = [ '/etc/init.d' ];
    }

    $self;
}

=item _isSysvinit( $service [, $nocache = FALSE] )

 is the given service a SysVinit script?

 Param string $service Service name
 Param bool $nocache OPTIONAL If true, no cache will be used
 Return bool TRUE if the service is a SysVinit script, FALSE otherwise

=cut

sub _isSysvinit
{
    my ( $self, $service, $nocache ) = @_;

    eval { $self->_searchInitScript( $service, $nocache ); };
}

=item searchInitScript( $service, [ $nocache =  FALSE ] )

 Search the SysVinit script that belongs to the given service in all available paths

 Param string $service Service name
 Param bool $nocache OPTIONAL If true, no cache will be used
 Return string Init script path on success, die on failure

=cut

sub _searchInitScript
{
    my ( $self, $service, $nocache ) = @_;

    # Make sure that init scrips are searched once
    CORE::state %initScripts;

    if ( $nocache ) {
        delete $initScripts{$service};
    } elsif ( exists $initScripts{$service} ) {
        defined $initScripts{$service} or croak( sprintf( "SysVinit script %s not found", $service ));
        return $initScripts{$service};
    }

    for my $path ( @{ $self->{'sysvinitscriptpaths'} } ) {
        my $initScriptPath = File::Spec->join( $path, $service );
        $initScripts{$service} = $initScriptPath if -f $initScriptPath;
        last if $initScripts{$service};

        $initScriptPath .= '.sh';
        $initScripts{$service} = $initScriptPath if -f $initScriptPath;
    }

    $initScripts{$service} = undef unless $nocache || $initScripts{$service};
    $initScripts{$service} or croak( sprintf( "SysVinit script %s not found", $service ));
    $nocache ? delete $initScripts{$service} : $initScripts{$service};
}

=item _exec( \@command, [ \$stdout [, \$stderr ]] )

 Execute the given command

 It is possible to capture both STDOUT and STDERR output by providing scalar
 references. STDERR output is used for raising failure when the command status
 is other than 0 and if no scalar reference has been provided for its capture.

 Param array_ref \@command Command to execute
 Param scalar_ref \$stdout OPTIONAL Scalar reference for STDOUT capture
 Param scalar_ref \$stderr OPTIONAL Scalar reference for STDERR capture
 Return int Command exit status, croak on failure if the command status is other than 0 and if no scalar reference has been provided for STDERR

=cut

sub _exec
{
    my ( undef, $command, $stdout, $stderr ) = @_;

    my $ret = execute( $command, ref $stdout eq 'SCALAR' ? $stdout : \$stdout, ref $stderr eq 'SCALAR' ? $stderr : \$stderr );
    ref $stdout ? !length ${ $stdout } || debug( ${ $stdout } ) : !length $stdout || debug( $stdout );

    # Raise a failure if command status is other than 0 and if no scalar
    # reference has been provided for STDERR, giving choice to callers
    croak( $stderr || 'Unknown error' ) if $ret && ref $stderr ne 'SCALAR';

    # We cache STDOUT output.
    # see _getLastExecOutput()
    $EXEC_OUTPUT = \( ref $stdout ? ${ $stdout } : $stdout );
    $ret;
}

=item _getLastExecOutput()

 Get output of last exec command

 return string Command STDOUT

=cut

sub _getLastExecOutput
{
    my ( $self ) = @_;

    ${ $EXEC_OUTPUT };
}

=item _getPs( )

 Get proper 'ps' invocation for the platform

 Return int Command exit status

=cut

sub _getPs
{
    my $distID = iMSCP::LsbRelease->getInstance()->getId( 'short' );

    if ( $distID eq 'OpenWrt' ) {
        'ps www';
    } elsif ( grep ( $distID eq $_, qw/ FreeBSD NetBSD OpenBSD Darwin DragonFly / ) ) {
        'ps auxwww';
    } else {
        'ps -ef'
    }
}

=item _getPid( $pattern )

 Get the process ID for a running process

 Param Regexp $pattern PID pattern
 Return int|undef Process ID or undef if not found

=cut

sub _getPid
{
    my ( $self, $pattern ) = @_;

    defined $pattern or croak( 'Missing or undefined $pattern parameter' );

    my $ps = $self->_getPs();
    open my $fh, '-|', $ps or croak( sprintf( "Couldn't pipe to %s: %s", $ps, $! ));

    while ( my $line = <$fh> ) {
        next unless $line =~ /$pattern/;
        return ( split /\s+/, $line =~ s/^\s+//r )[1];
    }

    undef;
}

=back

=head1 AUTHOR

 Laurent Declercq <l.declercq@nuxwin.com>

=cut

1;
__END__
