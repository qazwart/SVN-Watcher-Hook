#! /usr/bin/env perl
# svn-watch.pl

use strict;
use warnings;
use feature qw(say);

use File::Basename;
use Getopt::Long;
use Data::Dumper;
use Pod::Usage;

sub debug;

use constant {
    DIRECTORY_DEFAULT => "watchers",
    SUFFIX_DEFAULT    => "cfg",
    DOMAIN_DEFAULT    => "mfxfairfax.com",
    SMTP_HOST_DEFAULT => "MFXRKEDMA01.mfxservices.intr",
    SENDER_DEFAULT    => 'MFXCMJira@mfxfairfax.com',
    SVNLOOK_DEFAULT   => "/usr/bin/svnlook",
    DEBUG_DEFAULT     => "0",
    URL_DEFAULT       => "http://mfrklxmfxcmp01.mfxservices.intr/src",
    SUBJECT_DEFAULT   => "[SVN-WATCH] Revision %REVISION%: Change in "
      . "Subversion repository",
};

use constant {
    WATCH_EMAIL_LINE => qr/^\s*e?mail\s*=\s*(.*)/,
    WATCH_GLOB_LINE  => qr/^\s*(?:file|glob)\s*=\s*(.*)/,
    WATCH_REGEX_LINE => qr/^\s*(?:match|regex)\s*=\s*(.*)/,
};

#
#   Default Notification Message
#

use constant MESSAGE_DEFAULT => <<MESSAGE;
%USER%:

A file that you are watching in the Subversion repository has been
changed. You are being notified of this change because you have
configured your Subversion repository watch file to detect this change.

Subversion Repository: %URL%
Subversion Revision: %REVISION%
Author of Change: %AUTHOR%

Commit Message: %COMMIT%

Files that were changed:
------------------------------------------------------------------------
%CHANGED%

To modify your watch files, you need to checkout your watchfile and modify
it. Your watch file is at %URL%/%WATCHFILE%.

MESSAGE

########################################################################
# GET COMMAND LINE OPTIONS
#
my $watch_file_dir    = DIRECTORY_DEFAULT;
my $watch_file_suffix = SUFFIX_DEFAULT;
my $default_domain    = DOMAIN_DEFAULT;
my $smtp_host         = SMTP_HOST_DEFAULT;
my $message_sender    = SENDER_DEFAULT;
my $subject           = SUBJECT_DEFAULT;
my $svnlook_cmd       = SVNLOOK_DEFAULT;
our $debug_level = DEBUG_DEFAULT;
my $repository_url = URL_DEFAULT;

my ( $revision, $message_file, $smtp_user, $smtp_password, $help, $options,
    $no_email );

GetOptions(
    "debug=i"        => \$debug_level,
    "directory=s"    => \$watch_file_dir,
    "domain=s"       => \$default_domain,
    "help"           => \$help,
    "message=s"      => \$message_file,
    "noemail"        => \$no_email,
    "options"        => \$options,
    "revision=s"     => \$revision,
    "sender=s"       => \$message_sender,
    "smtphost=s"     => \$smtp_host,
    "smtppassword=s" => \$smtp_password,
    "smtpuser=s"     => \$smtp_user,
    "subject=s"      => \$subject,
    "svnlook=s"      => \$svnlook_cmd,
    "suffix=s"       => \$watch_file_suffix,
    "url=s"          => \$repository_url,
) or pod2usage( { -message => "ERROR: Invalid Parameter" } );

my $repository = $ARGV[0];

if ($help) {
    pod2usage(
        {
            -message =>
qq(Use "svn-watch.pl -options" to see a detailed description of the parameters),
            -exitstatus => 0,
            -verbose    => 0,
        }
    );
}

if ($options) {
    pod2usage( { -exitstatus => 0 } );
}

if ( not $repository ) {
    pod2usage( { -message => "ERROR: Missing Repository directory" } );
}

if ( not $revision ) {
    pod2usage( { -message => "ERROR: Missing revision number" } );
}

my $message;
if ($message_file) {
    open( my $message_fh, "$message_file" )
      or die( qq(ERROR: Message File "$message_file" )
          . qq(can't be opened for reading: $!\n) );
    $message = join "\n" => <$message_fh>;
    close $message_fh

}
else {
    $message = MESSAGE_DEFAULT;
}

chomp( my $author  = qx($svnlook_cmd author -r $revision "$repository") );
chomp( my $comment = qx($svnlook_cmd log -r $revision "$repository") );

my $watch = Watch->new(
    {
        author     => $author,
        comment    => $comment,
        domain     => $default_domain,
        message    => $message,
        revision   => $revision,
        repository => $repository,
        sender     => $message_sender,
        subject    => $subject,
        smtphost   => $smtp_host,
        url        => $repository_url,
        watch_dir  => $watch_file_dir,
    }
);

$watch->Smtp_User($smtp_user)         if ( defined $smtp_user );
$watch->Smtp_Password($smtp_password) if ( defined $smtp_password );

#
########################################################################

########################################################################
# GATHER WATCHFILE NAMES AND USERS
#
foreach
  my $watch_file (qx($svnlook_cmd tree -N "$repository" "$watch_file_dir"))
{
    chomp($watch_file);
    $watch_file =~ s/^\s+//;
    my $user = $watch_file;
    next if $user !~ s/\.$watch_file_suffix$//;
    next if $author eq $user;    #Don't notify watcher if they did commit
    my $watcher = Watcher->new( $user, $watch_file );
    $watch->Watcher($watcher);
}

#
########################################################################

########################################################################
# GO THROUGH ALL WATCHERS AND GATHER THE INFORMATION
#
if ( not defined $watch->Watcher ) {
    exit 0;    #No watchers Defined. No need to do any further processing
}

foreach my $watcher ( $watch->Watcher ) {
    my $watch_file = $watcher->Watch_File;
    my $repository = $watch->Repository;
    foreach
      my $line (qx[$svnlook_cmd cat $repository "$watch_file_dir/$watch_file"])
    {
        chomp $line;
        my ( $type, $value ) = process_line($line);
        next if not $type;    #Line not valid if process_line returns null;
        if ( $type eq "EMAIL" and not $no_email ) {
            $watcher->Email_List($value);
        }
        elsif ( $type eq "REGEX" ) {
            $watcher->Watch_List($value);
        }
        elsif ( $type eq "GLOB" ) {
            my $regex = glob2regex($value);
            $watcher->Watch_List($regex);
        }
    }
}

#
########################################################################

########################################################################
# NOW FOR EACH CHANGE, SEE IF A USER IS WATCHING FOR IT
#
foreach my $line (qx/$svnlook_cmd changed -r $revision "$repository"/) {
    chomp($line);
    foreach my $watcher ( $watch->Watcher ) {
        my ( $change_type, $file_changed ) = split( /\s+/, $line, 2 );
        if ( $watcher->Find($file_changed) ) {
            $watcher->Notify($line);
        }
    }
}

#
########################################################################

########################################################################
# SEND OUT THE NOTIFICATIONS
#
foreach my $watcher ( $watch->Watcher ) {
    if ( $watcher->Notify ) {
        $watch->Send_Email($watcher);
    }
}
exit $debug_level;

#
########################################################################

########################################################################
# Subroutine debug
#
# This function prints out the debugging information based upon

sub debug {
    my $message       = shift;
    my $message_level = shift;

    our $debug_level;
    $message_level = 1 if not defined $message_level;
    return if $message_level > $debug_level;
    my $print_message = "    " x $message_level . "DEBUG: $message\n";
    print STDERR $print_message;
    return $print_message;
}
########################################################################
# Subroutine process_line
#
# This function takes a line from the Watch file, and determines if it
# is an email address, a regular expression, or a glob, and returns
# a two member list. The 0th member of the list will be the string
# "EMAIL", "REGEX", or "GLOB" and the second member will be the
# email address, regular expression, or glob returned.
#
sub process_line {
    my $line = shift;

    chomp $line;
    if ( $line =~ /@{[WATCH_EMAIL_LINE]}/i ) {
        return ( EMAIL => $1 ), 4;
    }
    elsif ( $line =~ /@{[WATCH_GLOB_LINE]}/i ) {
        return ( GLOB => $1 );
    }
    elsif ( $line =~ /@{[WATCH_REGEX_LINE]}/i ) {
        return ( REGEX => $1 );
    }
    else {
        return;
    }
}

#
########################################################################

########################################################################
# SUBROUTINE glob2regex
#
# Globs are easier for developers, but Perl uses regular expressions.
# This means we have to convert from one to the other. In Ant Globs,
# the following characters have special meaning:
#
# ? - Match any single character. Equivelent to: .
# * - Match any string of characters with in a directory.
# ** - Match any string of characters in a directory tree:
#
# The questionmark is easy: It's equal to the regular expression period (.)
#
# The single astrisk is harder. It can be a string of characters of any
# length, but it can't include a directory separator. That's [^/]*.
#
# Double astrisk is like the .* match in regular expressions
#
# Here's the trick: When we see a single astrisk, we have to wait until
# we check the character after it. If it's also an astrisk, we know to
# substitute .* for both of them. If the next letter isn't an asstrisk,
# we need to substiture [^/]* for the astrisk and then figure out what
# to do with the next character.
#
# We also have to quote out special regular expression characters to
# remove their magic, and while we're at it, we will also translate
# back slashes (which are directory separartors in Windows to forward
# slashes.
#
sub glob2regex {
    my $glob = shift;

    my $regex            = undef;
    my $previous_astrisk = undef;

    foreach my $letter ( split( //, $glob ) ) {

        #
        #    ####Check if previous letter was astrisk
        #
        if ($previous_astrisk) {
            if ( $letter eq "*" ) {    #Double astrisk
                $regex .= ".*";
                $previous_astrisk = undef;
                next;
            }
            else {   #Single astrisk: Write prev match and handle current letter
                $regex .= "[^/]*";
                $previous_astrisk = undef;
            }
        }

        #
        #   ####Quote all Regular expression characters w/ no meaning in glob
        #
        if ( $letter =~ /[\{\}\.\+\(\)\[\]]/ ) {
            $regex .= "\\$letter";

            #
            #   ####Translate "?" to Regular expression equivelent
            #
        }
        elsif ( $letter eq "?" ) {
            $regex .= ".";

        #
        #   ####You don't know how to handle astrisks until you see the next one
        #
        }
        elsif ( $letter eq "*" ) {
            $previous_astrisk = 1;

            #
            #   ####Convert backslashes to forward slashes
            #
        }
        elsif ( $letter eq '\\' ) {
            $regex .= "/";

            #
            #   ####Just a letter
            #
        }
        else {
            $regex .= $letter;
        }
    }

    #
    #   ####Handle if last letter was astrisk
    #
    if ($previous_astrisk) {
        $regex .= "[^/]*";
    }

    #
    #    ####Globs are anchored to both beginning and ending
    #
    $regex = "^$regex\$";
    return $regex;
}

#
########################################################################

########################################################################
# PACKAGE WATCH
#
# This object type tracks the basic information the program needs to
# run. For example, Author, Repository, Etc. It also contans the list
# of file changes associated with the list. These changes are of the
# type "Change". And, it also keeps track of all the watchers. These
# are object type "Watcher"
#
package Watch;

use Carp;
use Net::SMTP;
use Data::Dumper;

########################################################################
# CONSTRUCTOR Watch->new
#
# Parameters: Hash
# Return:     Watch Object
#
sub new {
    my $class = shift;
    my %params = %{ (shift) };

    my $self = {};
    bless $self, $class;

    $self->Author( $params{author} );
    $self->Comment( $params{comment} );
    $self->Default_Domain( $params{domain} );
    $self->Message( $params{message} );
    $self->Revision( $params{revision} );
    $self->Repository( $params{repository} );
    $self->Sender( $params{sender} );
    $self->Smtp_Host( $params{smtphost} );
    $self->Smtp_Password( $params{smtppass} );
    $self->Subject( $params{subject} );
    $self->Url( $params{url} );
    $self->Watch_Dir( $params{watch_dir} );

    return $self;
}

#
########################################################################

########################################################################
# Method Watch->Author
#
# Getter/Setter of user who committed the change
#
sub Author {
    my $self   = shift;
    my $author = shift;

    if ( defined $author ) {
        $self->{AUTHOR} = $author;
    }
    return $self->{AUTHOR};
}

#
########################################################################

########################################################################
# Method Watch->Comment
#
# Getter/Setter of commit message
#
sub Comment {
    my $self    = shift;
    my $command = shift;

    if ( defined $comment ) {
        $self->{COMMENT} = $comment;
    }
    return $self->{COMMENT};
}

#
########################################################################

########################################################################
# Method Watch->Default_Domain
#
# Getter/Setter of email default domain
#
sub Default_Domain {
    my $self   = shift;
    my $domain = shift;

    if ( defined $domain ) {
        $self->{DOMAIN} = $domain;
    }
    return $self->{DOMAIN};
}

#
########################################################################

########################################################################
# Method Watch->Message
#
# Getter/Setter of email template message
#
sub Message {
    my $self    = shift;
    my $message = shift;

    if ( defined $message ) {
        $self->{MESSAGE} = $message;
    }
    return $self->{MESSAGE};
}

#
########################################################################

########################################################################
# Method Watch->Repository
#
# Getter/Setter of Subversion repository directory location
#
sub Repository {
    my $self       = shift;
    my $repository = shift;

    if ( defined $repository ) {
        $self->{REPOSITORY} = $repository;
    }
    return $self->{REPOSITORY};
}

#
########################################################################

########################################################################
# Method Watch->Sender
#
# Getter/Setter of email address for sender
#
sub Sender {
    my $self   = shift;
    my $sender = shift;

    if ( defined $sender ) {
        $self->{SENDER} = $sender;
    }
    return $self->{SENDER};
}

#
########################################################################

########################################################################
# Method Watch->Smtp_Host
#
# Getter/Setter of SMTP Host
#
sub Smtp_Host {
    my $self = shift;
    my $host = shift;

    if ( defined $host ) {
        $self->{SMTP_HOST} = $host;
    }
    return $self->{SMTP_HOST};
}

#
########################################################################

########################################################################
# Method Watch->Smtp_User
#
# Getter/Setter of Account needed for connecting to SMTP host
#
sub Smtp_User {
    my $self = shift;
    my $user = shift;

    if ( defined $user ) {
        $self->{SMTP_USER} = $user;
    }
    return $self->{SMTP_USER};
}

#
########################################################################

########################################################################
# Method Watch->Smtp_Password
#
# Getter/Setter of password for account needed for connecting to SMTP Host
#
sub Smtp_Password {
    my $self = shift;
    my $pass = shift;

    if ( defined $pass ) {
        $self->{SMTP_PASSWORD} = $pass;
    }
    return $self->{SMTP_PASSWORD};
}

#
########################################################################

########################################################################
# Method Watch->Subject
#
# Getter/Setter for Email Watch Subject Line
#
sub Subject {
    my $self    = shift;
    my $subject = shift;

    if ( defined $subject ) {
        $self->{SUBJECT} = $subject;
    }
    return $self->{SUBJECT};
}

#
########################################################################

########################################################################
# Method Watch->Url
#
# Getter/Setter of URL for subversion repository
#
sub Url {
    my $self = shift;
    my $url  = shift;

    if ( defined $url ) {
        $self->{URL} = $url;
    }
    return $self->{URL};
}

#
########################################################################

########################################################################
# Method Watch-Watch_Dir
#
# Getter/Setter of Watch Directory in Repository
#
sub Watch_Dir {
    my $self      = shift;
    my $directory = shift;

    if ( defined $directory ) {
        $self->{WATCH_DIR} = $directory;
    }
    return $self->{WATCH_DIR};
}

#
########################################################################

########################################################################
# Method Watch->Revision
#
# Getter/Setter of Subversion revision that triggered post-commit hook
#
sub Revision {
    my $self = shift;
    my $rev  = shift;

    if ( defined $rev ) {
        $self->{REVISION} = $rev;
    }
    return $self->{REVISION};
}

#
########################################################################

########################################################################
# Method Watch->Change
#
# List of Change->new objects. If a Change object is passed as a parameter,
# the Change object is pushed onto the list.
# Returns a list of Change Objects
#
sub Change {
    my $self   = shift;
    my $change = shift;

    $self->{CHANGE} = [] if not exists $self->{CHANGE};
    if ( defined $change ) {
        if ( ref($change) ne "Change" ) {
            croak qq(Change must be a "Change" object);
        }
        push @{ $self->{CHANGE} }, $change;
    }
    return @{ $self->{CHANGE} };
}

#
########################################################################

########################################################################
# METHOD Watch->Watcher
#
# List of Watchers->new objects. If a Watcher object is passed as a
# parameter, the Watcher object is pushed into the list.
# Returns a list of Watcher objects.
#
sub Watcher {
    my $self    = shift;
    my $watcher = shift;

    $self->{WATCHER} = [] if not exists $self->{WATCHER};
    if ( defined $watcher ) {
        if ( ref($watcher) ne "Watcher" ) {
            croak qq(Watcher must be a "Watcher" object);
        }
        push @{ $self->{WATCHER} }, $watcher;
    }
    return @{ $self->{WATCHER} };
}

#
########################################################################

########################################################################
# Method Watch->Send_Email
#
# Requires Watcher->new object parameter. This method sends an email out
# for all email address returned by Watcher->Email Method.
# list of changes the Watcher object is storing.
# Returns nothing
#
sub Send_Email {
    my $watch   = shift;
    my $watcher = shift;

    #
    # Create a Default Email if Watcher doesn't have one
    #
    if ( not $watcher->Email_List and $watch->Default_Domain ) {
        $watcher->Email_List( $watcher->User . '@' . $watch->Default_Domain );
    }

    #
    #  If Mail::Sendmail isn't installed, fallback to Net::SMTP
    #
    eval { require Mail::Sendmail; };
    if ($@) {
        $watch->_Send_Email_Net_SMTP($watcher);
        return;
    }

    #
    # Mail::Sendmail is installed: Use that
    #

    foreach my $email ( $watcher->Email_List ) {
        my $message = $watch->Munge_Message( $watcher, $email );
        my $subject =
          $watch->Munge_Message( $watcher, $email, $watch->Subject );

        unshift @{ $Mail::Sendmail::mailcfg{smtp} } => $watch->Smtp_Host;
        $Mail::Sendmail::mailcfg{debug} = $debug_level;
        my %mail = (
            From    => $watch->Sender,
            Subject => $subject,
            To      => $email,
            Message => $message,
        );
        Mail::Sendmail::sendmail(%mail);
    }
    return;
}

sub _Send_Email_Net_SMTP {
    my $watch   = shift;
    my $watcher = shift;

    foreach my $email ( $watcher->Email_List ) {

        my $smtp = Net::SMTP->new(
            Host  => $watch->Smtp_Host,
            Debug => $debug_level,
        );

        if ( not defined $smtp ) {
            croak qq(Unable to connect to mailhost "@{[$watch->Smtp_Host]}");
        }

        if ($smtp_user) {
            $smtp->auth( $watch->Smtp_User, $watch->Smtp_Password )
              or croak
              qq(Unable to connect to mailhost "@{[$watch->Smtp_Host]}")
              . qq( as user "@{[$watch->Smtp_User]}");
        }

        if ( not $smtp->mail( $watch->Sender ) ) {
            carp qq(Cannot send as user "@{[$watch->Sender]}")
              . qq( on mailhost "@{[$watch->Smtp_Host]}");
            next;
        }
        if ( not $smtp->to($email) ) {
            $smtp->reset;
            next;    #Can't send email to this address. Skip it
        }

        #
        # Prepare Message
        #
        # In Net::SMTP, the Subject and the To fields are actually part
        # of the message with a separate blank line separating the
        # actual message from the header.
        #
        my $message = $watch->Munge_Message( $watcher, $email );
        my $subject =
          $watch->Munge_Message( $watcher, $email, $watch->Subject );

        $message = "To: $email\n" . "Subject: $subject\n\n" . $message;

        $smtp->data;
        $smtp->datasend("$message");
        $smtp->dataend;
        $smtp->quit;
    }
    return;
}

#
########################################################################

########################################################################
# Method Watch->Munge_Message
#
# Paramters:
#    Watch object   (Required)
#    Email Address  (Required)
#    Text to Munge  (Optional)
#
# This module taks the information needed from the Watch object, the
# email address passed, and the optional text field, and replaces the
# following parameters in the text with these fields.
#
# If Text to Munge is not given, then the Watch->Message is used.
#
#  %EMAIL%     -> Passed in email address
#
#  %REVISION%  -> Watch->Revision
#  %URL%       -> Watch->Url
#  %AUTHOR%    -> Watch->Author
#  %COMMIT%    -> Watch->Comment
#
#  %USER%      -> Watcher->User
#  %WATCHFILE% -> Watcher->Watch_File
#  %CHANGED%   -> Watcher->Notify
#
sub Munge_Message {
    my $watch   = shift;
    my $watcher = shift;
    my $email   = shift;
    my $message = shift;

    $message = $watch->Message if not defined $message;

    $message =~ s/%EMAIL%/$email/g;
    $message =~ s/%AUTHOR%/@{[$watch->Author]}/g;
    $message =~ s/%COMMIT%/@{[$watch->Comment]}/g;
    $message =~ s/%REVISION%/@{[$watch->Revision]}/g;
    $message =~ s/%URL%/@{[$watch->Url]}/g;
    $message =~ s/%USER%/@{[$watcher->User]}/g;
    my $changes = $watcher->Notify;
    $message =~ s/%CHANGED%/$changes/g;

    my $watch_file = $watch->Watch_Dir . "/" . $watcher->Watch_File;
    $message =~ s/%WATCHFILE%/$watch_file/g;

    return $message;
}

#
########################################################################

########################################################################
# Package Watcher
#
# This object type is for the individual Watcher and tracks the
# name of their watchfile, the email addresses where they want their
# notifications sent, the files (in regex format) they want to watch,
# and all matching changes in the particular Subversion revision.
#
package Watcher;

use Carp;

########################################################################
# Constructor Watcher->new
#
# Creates a new Watcher object.
#
sub new {
    my $class      = shift;
    my $user       = shift;
    my $watch_file = shift;

    my $self = {};
    bless $self, $class;

    $self->User($user)             if defined $user;
    $self->Watch_File($watch_file) if defined $watch_file;

    return $self;
}

#
########################################################################

########################################################################
# Method Watcher->User
#
# Getter/Setter of Watcher's Subversion user ID
#
sub User {
    my $self = shift;
    my $user = shift;

    if ( defined $user ) {
        $self->{USER} = $user;
    }
    return $self->{USER};
}

#
########################################################################

########################################################################
# Method Watcher->Watch_File
#
# Getter/Setter of the Watcher's watchfile in the Subversion repository
#
sub Watch_File {
    my $self       = shift;
    my $watch_file = shift;

    if ( defined $watch_file ) {
        $self->{WATCHFILE} = $watch_file;
    }
    return $self->{WATCHFILE};
}

#
########################################################################

########################################################################
# Method Watcher->Email_List
#
# Getter/Setter of email list of where the Watcher wants their
# notifcations sent. If an Email address is passed as a parameter, it
# will be pushed onto the list of email addresses. Returns a list of
# email addresses.
#
# Email addresses are stored in a hash in order to prevent duplicates
#
sub Email_List {
    my $self  = shift;
    my $email = shift;

    if ( defined $email ) {
        $self->{EMAIL} = {} if not exists $self->{EMAIL};
        $self->{EMAIL}->{$email} = $email;
    }
    return sort keys %{ $self->{EMAIL} };
}

#
########################################################################

########################################################################
# Method Watcher->Watch_List
#
# Getter/Setter of list of files being watched in regex format. If a
# regular expression is passed to this routine, it will be added to the
# list of files being watched. Returns a list of regular expressions
# of files being watched.
#
sub Watch_List {
    my $self  = shift;
    my $watch = shift;

    $self->{WATCH} = [] if not exists $self->{WATCH};
    if ( defined $watch ) {
        push @{ $self->{WATCH} }, $watch;
    }
    return sort @{ $self->{WATCH} };
}

#
########################################################################

########################################################################
# Method Watcher->Find
#
# This method takes a file name, and checks it against the
# Watcher-Watch_List to see if there are any matches. If a match is
# found, it will be returned. Otherwise, nothing is returned.
#
sub Find {
    my $self = shift;
    my $file = shift;

    $file = "/" . $file if $file =~ m(^/);
    foreach my $watch_regex ( $self->Watch_List ) {
        if ( $file =~ /$watch_regex/ ) {
            return $watch_regex;
        }
    }
    return;    #No files found
}

#
########################################################################

sub Notify {
    my $self   = shift;
    my $change = shift;

    $self->{CHANGE} = [] if not exists $self->{CHANGE};
    if ( defined $change ) {
        push @{ $self->{CHANGE} }, $change;
    }
    if (wantarray) {
        return sort @{ $self->{CHANGE} };
    }
    else {
        return join "\n" => @{ $self->{CHANGE} };
    }
}

#
########################################################################

__END__

=pod

=head1 NAME

svn-watch.pl

=head1 SYNOPSIS

    svn-watch.pl -r <rev> [-directory <dir>] [-suffix <suffix>] \
        [-domain <domain>] [-smtphost <host>] [-message <message>] \
        [-sender <sender>] [-svnlook <svnlook>] [-subject <subject>] \
        [-debug <debuglevel>] [-url <url>] [-noemail] \
        [-smtpuser <host> -smtppassword <passwd>] <repos>
or
    svn-watch.pl -help

or
    svn-watch.pl -options

=head1 DESCRIPTION

This program implements watchlists in Subversion. A watchlist is a list
of files that a particular user would be notified on if changes occur in
a file that user was watching. Although there are many similar programs
like this for Subversion, most require access to the Subversion server
to set, so users are unable to set their own watch lists.

This program, however, allows users of Subversion to set their own watch
lists since the watch list is actually stored in the Subversion
repository itself. 

In the user's watchlist, the user specifies the various email addresses 
where notifications are sent when a file they were watching was
modified. Users are allowed to specify multiple email addresses, and the
program can be configured to automatically email the user at a default
email address if the user didn't specify one. The default email address
is set to the user's Subversion account name at the default domain
provided when executing this program.

Users can specify the files thwy are watching using Ant globbing (which
has very straight forward syntax) or Perl regular expressions (which are
more powerful, but the syntax is trickier).

=head1 INSTALLATION

This program operates as a Subversion post-commit trigger and is
automatically executed after each revision.

=head2 REQUIREMENTS

=over 4

=item *

Perl 5.7 or later.

=item *

Mail::Sendmail (optional). This is an optional Perl module to install.
It's very old, but straightforward and usually works without too many
issues. You can use the Perl CPAN utility to install this module.

If this module is not installed, this program will automatically use the
Net::SMTP module which is a standard Perl module, so it doesn't have to
be installed. Unfortunately, this module sometimes fails and crashes the
post-commit process leaving the Subversion client confused. Still,
almost all sites have successfully used this program without installing
Mail::Sendmail.

=back

=head2 WINDOWS

Copy this program into your Subversion repository's F<hook> directory.
Copy or rename the post-commit.tmpl script to F<post-commit.bat>. Modify
the F<post-commit.bat> file to execute this script. The PATH environment
will not be set when the hook executes, so you need to include both the
path to your Perl interpreter and to this program:

    set REV=%1
    set REPOS=%2
    C:\Perl\bin\perl %REPOS%\hooks\svn-watch.pl -r %REV% %REPOS%

=head2 UNIX, LINUX, MAC OS X, AND OTHER B<REAL> OPERATING SYSTEMS

Copy this program into your Subversion repository's F<hook> directory.
Copy or rename the post-commit.tmpl script to F<post-commit>. Modify
the F<post-commit> script to execute this script. The PATH environment
will be set to the default C</bin:/usr/bin>, so if your Perl interpreter
is located in C</usr/local/bin> or some other non-standard place, you'll
need to put the path to your Perl's interpreter and the perl interpreter
in the script:

    REV=$1
    REPOS=$2

    # If you have Perl located in F</usr/bin> or F</bin>

    $REPOS/hooks/svn-watch.pl -r $REV $REPOS

    # If you have Perl in a funky location

    /usr/local/bin/perl5.8 $REPOS/hooks/svn-watch.pl -r $REV $REPOS

path to your Perl interpreter and to this program:

=head2 DIRECTIONS

The default location for the watch files is in the root of the
repository under a directory called F</watchers>. This can be modified
by using the command line parameters. However, you shouldn't put this
file in under the F<trunk>, F<branches>, or F<tags> directory, nor
should it be placed in a module sub-directory.

The user's watch file will be the user's Subversion account name
followed by a suffix. The default suffix is F<.cfg>, but again the
suffix can be changed by the command line parameters.  You can use
the F<pre-commit-kitchen-sink-hook.pl> program (also available from
DaveCo Software and Bait Shoppe, LLC) to prevent users from editing
other users' watch files.

=head1 WATCH FILE LAYOUT

Each line in the Watchfile is one of six formats. (There are three line
types and each has a synonym). Any other line not in one of these
formats is ignored.

=over 2

=item *

C<email = >I<E<lt>User's Email AddressE<gt>>

=item *

C<mail = >I<E<lt>User's Email AddressE<gt>>

=item *

C<file = >I<E<lt>Ant's Glob Description of the File to WatchE<gt>>

=item *

C<glob = >I<E<lt>Ant's Glob Description of the File to WatchE<gt>>

=item *

C<match = >I<E<lt>Perl Regular Expression fo the File to WatchE<gt>>

=item *

C<regex = >I<E<lt>Perl Regular Expression fo the File to WatchE<gt>>

=back

The line type at the beginning of the line is case insensitive. All white space
at the beginning and end of the line is also ignored as well as the white space
around the equals sign. All of the following lines do the same thing:

    email = bob@mycompany.com
    email=bob@mycompany.com
    EMAIL = bob@mycompany.com
    EmAiL = bob@mycompany.com
    EmAiL=     bob@mycompany.com


The three different types of lines are:

=over 4

=item email or mail:

The email address the notification is sent to. Users can have more than one
B<email> line, and a notification message will be sent to all of them.

=item file or glob:

Specifies a file to be watched. This specification is in Ant's globbing syntax
which is easier and more familar than regular expressions. The globbing syntax
has three parts.

=over 5

=item B<*>

A single astrisk represents zero or more characters, but only with in the
directory. Thus, if you specify:

    file = /projects/myproj/*/*.java

A watch would be placed on all Java files in the directory
C</project/myproj/foo/> and in C</project/myproj/bar>, but not Java files in
C</project/myproj/foo/bar> since only the directories right below
C</project/myproj> were specified and not any of their subdirectories.

=item B<?>

A question mark represents a single character. So
C</project/myproj/foo/apple?.java> would place a watch on
C</project/myproj/foo/apple1.java> and C</project/myproj/foo/apple2.java>, but
not C</project/myproj/foo/apple.java> or C</project/myproj/foo/apple12.java>.

=item B<**>

A double astrisk represents any number of characters in any directory or
subdirectory tree. C</project/myproj/foo/**/*.java> would place a watch on any
Jaa file under the C</project/myproj/foo> directory tree.

=back 

=item match or regex:

This specifies a match using the full set of Perl regular expressions.
Perl regular expressions are more complex than simple globs, but gives
the user much more power over matching file names. For example, a single
Perl regular expression can match multiple suffixes in a file.

Regular expressions do not require slashes before and after, and should
not be in quotes. Regular expressions are not anchored, so C<foo> would
match any occurance of C<foo> in the file name. You can use the standard
Perl anchors of C<^> and C<$> to anchor a regular expression at teh
beginning or end of a line.

For more information on Perl regular expressions, type in the following
command:

    $ perldoc perlre

=item B<NOTE>:

All glob expressions are anchored to the root of the repository direcotry. And,
the root of the directory tree starts with a slash. Thus, merely specifying
C<myproj/*.java> will not put a watch on any file. However, users can specify a
double at the beginning of their file specification to remove this anchoring.
Thus C<**/myproj/**/*.java> would place a watch on any Java file under a
directory C<myproj> located anywhere in the repository.

=back

=head2 WATCH FILE LINE EXAMPLES

=over 4

=item * 

Send an email to Bob's Acme's email address

    mail = bob@acme.com

=item *

Send an email to Bob's Cellphone pager

    email = 2125554567@verizon.net

=item *

Let me know when any build.xml file is modified

    file = **/build.xml

=item *

Let me know when someone modifies any help files

    glob = **/main/src/**/help/**

=item *

Let me know if someone modifies an shell script or Perl script

    match = \.(pl|sh|ksh|bash)$

=item *

Let me know if someone modifies any build.xml file I suspect that some
are in the format build-*.xml or build.*.xml:

    regex = build(-\.)\w+\.xml$

=back

=head1 OPTIONS

=over 12

=item -r:

B<REQUIRED> This is the revision number used for the post-commit trigger
and is  passed as the second command line argument to the post-commit
trigger.

=item -directory:

Name of the directory in the repository where the Watch files are
stored. Only files stored directly under this directory will be examined
as watchfiles files in sub-directories will be ignored.

The default is C</watchers>.

=item -suffix:

The suffix for watch files. Watch files are the same name as the
subversion user ID plus the suffix. If a watch file does not have this
suffix, it will be ignored. Suffixes are added to the file after a
period, so you don't have to specify the beginning period. However, if
you do, it will be ignored.

The default is C<cfg>

For example, if both the default for C<-directory> and C<-suffix> are
kept, user C<bob> would have the watch file C</watchfiles/bob.cfg>.

=item -domain:

The domain to add to user names if the user does not specify an email
address for example, if the domain is set to C<mycompany.com> and user
I<bob> is suppose to receive a notification message, the message will be
sent to C<bob@mycompany.com>.

=item -smtphost:

The SMTP host used for sending email messages.

=item -message:

This is a text file that contains the message to email to users when a
file they are watching is changed.  Certain keywords  are replaced with
values taken from the notificaiton list. If you use your own message,
you can include these special keywords in your own message.

=over 15

=item %AUTHOR%

The name of the user who did the commit.

=item %CHANGED%

A list of all the files changed that the user is interested in. This
listing is one per line.

=item %COMMIT%

The commit message made by the author at the time of the commit.
B<NOTE>: The commit message can be more than one line long. Remember
that when you format your notification message.

=item %EMAIL%

The email address of the user.

=item %REVISION%

The revision of the Subverision repository.

=item %URL%

The URL used by the users to access the Subversion repository.

=item %USER%

The Subversion user ID of the user getting the notificaiton message.

=item %WATCHFILE%

The name of the user's watchfile including its full path.

=back

=item -sender

The email address you want to appear as the sender of the notification
message. Note this will be the address used if a user replies to their
notification message.

Default can be seen via C<svn-watch.pl -help>.

=item -svnlook:

The location of the C<svnlook> command.

The default is C</usr/bin/svnlook>.

=item -debug

This is the debug level. The higher the number, the more debugging
messages.

The default is "0" which means no debugging informtion.

=item -url

This is the URL that the users normally use to access the Subversion
repository. This is mainly used for the notification email message
sent to the users.

=item -smtpuser -smtppassword

These two items are required if your SMTP server uses authorization.
The C<-smtpuser> is the user, the C<-smtppassword)> is the password to
use, and the C<-smtpauth> is the authorization type needed for sending
the user name and password.

=item -subject

This is the subject line that will appear on emails sent out ot
watchers.  Certain keywords  are replaced with values taken from the
notificaiton list. If you use your own subject line, you can include
these special keywords in your own subject line.

=item -noemail

This option prevents users from defining their own email addresses.
Apparently, someone at one of the sites that used this couldn't
understand the concept that he wasn't suppose to tell other peoplw
what files they were suppose to watch. If used, only the default
email address will be used.

=item I<< <repos> >>

B<REQUIRED>: The path to the root of the Subversion repository.

=item -help

Displays a brief help message just showing the command line options.

=item -options

Displays indepth help message showing the command line and description
of all the options.

=back

=head1 BUGS

=over 4

=item *

There is nothing preventing a user from entering someone else's email
address, and there's no easy way to catch this. We simply are trusting
everyone to act professionally.

=item *

This program doesn't show the diff between the files like C<svnnotify>
does.

=item *

It would be nice if this program could interface somehow with
svnnotify. An earlier version attempted to, but it never really worked
as advertised, and made the code more difficult to read. The whole thing
was removed in a later version.

=back

=head1 SEE ALSO

    svnnotify(1)

=head1 AUTHOR

David Weintraub E<lt>david@weintraub.nameE<gt>

=head1 COPYRIGHT

Copyright (c) 2011 by David Weintraub. All rights reserved. This
program is covered by the open source BMAB license.

The BMAB (Buy me a beer) license allows you to use all code for whatever
reason you want with these three caveats:

=over 4

=item 1.

If you make any modifications in the code, please consider sending them
to me, so I can put them into my code.

=item 2.

Give me attribution and credit on this program.

=item 3.

If you're in town, buy me a beer. Or, a cup of coffee which is what I'd
prefer. Or, if you're feeling really spendthrify, you can buy me lunch.
I promise to eat with my mouth closed and to use a napkin instead of my
sleeves.

=back

=cut
