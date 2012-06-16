# Hey emacs! This is a -*- Perl -*- script!
# Lintian::Util -- Perl utility functions for lintian

# Copyright (C) 1998 Christian Schwarz
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, you can find it on the World Wide
# Web at http://www.gnu.org/copyleft/gpl.html, or write to the Free
# Software Foundation, Inc., 51 Franklin St, Fifth Floor, Boston,
# MA 02110-1301, USA.

package Lintian::Util;
use strict;
use warnings;

use base 'Exporter';

use constant {
  DCTRL_DEBCONF_TEMPLATE => 1,
  DCTRL_NO_COMMENTS => 2,
};

# Force export as soon as possible, since some of the modules we load also
# depend on us and the sequencing can cause things not to be exported
# otherwise.
our (@EXPORT_OK, @EXPORT, %EXPORT_TAGS);
BEGIN {
    %EXPORT_TAGS = (
            constants => [qw(DCTRL_DEBCONF_TEMPLATE DCTRL_NO_COMMENTS)]
    );

    @EXPORT_OK = (qw(
                 visit_dpkg_paragraph
                 parse_dpkg_control
                 read_dpkg_control
                 get_deb_info
                 get_dsc_info
                 slurp_entire_file
                 file_is_encoded_in_non_utf8
                 fail
                 system_env
                 delete_dir
                 copy_dir
                 gunzip_file
                 touch_file
                 perm2oct
                 check_path
                 clean_env
                 resolve_pkg_path),
                 @{ $EXPORT_TAGS{constants} }
    );

    # Export by default due to its wide spread use in "one-liners" in
    # t/source/*/Makefile.
    @EXPORT = qw(get_file_checksum);

}

use Encode ();
use FileHandle;
use Lintian::Command qw(spawn);
use Lintian::Output qw(string);
use Digest::MD5;
use Scalar::Util qw(openhandle);

=head1 NAME

Lintian::Util - Lintian utility functions

=head1 SYNOPSIS

 use Lintian::Util qw(slurp_entire_file resolve_pkg_path);
 
 my $text = slurp_entire_file ('some-file');
 if ($text =~ m/regex/) {
    # ...
 }

 my $path = resolve_pkg_path ('/usr/bin/', '../lib/git-core/git-pull');
 if (-e $path) {
    # ....
 }
 
 my (@paragraphs);
 eval { @paragraphs = read_dpkg_control ('some/debian/ctrl/file'); };
 if ($@) {
    # syntax error etc.
    die "ctrl/file: $@";
 }
 
 foreach my $para (@paragraphs) {
    my $value = $para->{'some-field'};
    if (defined $value) {
        # ...
    }
 }

=head1 DESCRIPTION

This module contains a number of utility subs that are nice to have,
but on their own did not warrant their own module.

Most subs are imported only on request.

=head2 Debian control parsers

At first glance, this module appears to contain several debian control
parsers.  In practise, there is only one real parser
(L</visit_dpkg_paragraph>) - the rest are convience functions around
it.

If you have very large files (e.g. Packages_amd64), you almost
certainly want L</visit_dpkg_paragraph>.  Otherwise, one of the
convience methods are probably what you are looking for.

=over 4

=item Use L</get_deb_info> when

You have a I<.deb> (or I<.udeb>) file and you want the control file
from it.

=item Use L</get_dsc_info> when

You have a I<.dsc> (or I<.changes>) file.  Alternative, it is also
useful if you have a control file and only care about the first
paragraph.

=item Use L</read_dpkg_control> when

You have a debian control file (such I<debian/control>) and you want
a number of paragraphs from it.

=item Use L</parse_dpkg_control> when

When you would have used L</read_dpkg_control>, except you have an
open filehandle rather than a file name.

=back

=head1 CONSTANTS

The following constants can be passed to the Debian control file
parser functions to alter their parsing flag.

=over 4

=item DCTRL_DEBCONF_TEMPLATE

The file should be parsed as debconf template.  These have slightly
syntax rules for whitespace in some cases.

=item DCTRL_NO_COMMENTS

The file do not allow comments.  With this flag, any comment in the
file is considered a syntax error.

=back

=head1 FUNCTIONS

=over 4

=item parse_dpkg_control (HANDLE[, FLAGS[, LINES]])

Reads a debian control file from HANDLE and returns a list of
paragraphs in it.  A paragraph is represented via a hashref, which
maps (lower cased) field names to their values.

FLAGS (if given) is a bitmask of the I<DCTRL_*> constants.  Please
refer to L</CONSTANTS> for the list of constants and their meaning.
The default value for FLAGS is 0.

If LINES is given, it should be a reference to an empty list.  On
return, LINES will be populated to the line numbers where a given
paragraph "started" (i.e. the line number of first field in the
paragraph).

This is a convience sub around L</visit_dpkg_paragraph> and can
therefore produce the same errors as it.  Please see
L</visit_dpkg_paragraph> for the finer semantics of how the
control file is parsed.

NB: parse_dpkg_control does I<not> close the handle for the caller.

=cut

sub parse_dpkg_control {
    my ($handle, $flags, $lines) = @_;
    my @result;
    my $c = sub {
        my ($para, $line) = @_;
        push @result, $para;
        push @$lines, $line if defined $lines;
    };
    visit_dpkg_paragraph ($c, $handle, $flags);
    return @result;
}


=item visit_dpkg_paragraph (CODE, HANDLE[, FLAGS])

Reads a debian control file from HANDLE and passes each paragraph to
CODE.  A paragraph is represented via a hashref, which maps (lower
cased) field names to their values.

FLAGS (if given) is a bitmask of the I<DCTRL_*> constants.  Please
refer to L</CONSTANTS> for the list of constants and their meaning.
The default value for FLAGS is 0.

If the file is empty (i.e. it contains no paragraphs), the method will
contain an I<empty> list.  Lines looking like a GPG-signature is
ignored when parsing the file.

visit_dpkg_paragraph will pass paragraphs to CODE as they are
completed.  If CODE can process the paragraphs as they are seen, very
large control files can be processed without keeping all the
paragraphs in memory.

As a consequence of how the file is parsed, CODE may be passed a
number of (valid) paragraphs before parsing is stopped due to a syntax
error.

NB: visit_dpkg_paragraph does I<not> close the handle for the caller.

CODE is expected to be a callable reference (e.g. a sub) and will be
invoked as the following:

=over 4

=item CODE->(PARA, STARTLINE)

The first argument, PARA, is a hashref to the most recent paragraph
parsed.  The second argument, STARTLINE, is the line number where the
paragraph "started" (i.e. the line number of first field in the
paragraph).

The return value of CODE is ignored.

If the CODE invokes die (or similar) the error is propagated to the
caller.

=back


I<On syntax errors>, visit_dpkg_paragraph will call die with the
following string:

  "syntax error at line %d: %s\n"

Where %d is the line number of the issue and %s is one of:

=over

=item Duplicate field %s

The field appeared twice in the paragraph.

=item Continuation line outside a paragraph

A continuation line appears outside a paragraph - usually caused by an
unintended empty line before it.

=item Whitespace line not allowed (possibly missing a ".")

An empty continuation line was found.  This usually means that a
period is missing to denote an "empty line" in (e.g.) the long
description of a package.

=item Cannot parse line "%s"

Generic error containing the text of the line that confused the
parser.  Note that all non-printables in %s will be replaced by
underscores.

=item Comments are not allowed

A comment line appeared and FLAGS contained DCTRL_NO_COMMENTS.

=back

=cut

sub visit_dpkg_paragraph {
    my ($code, $CONTROL, $flags) = @_;
    $flags//=0;
    my $sline = -1;
    my $section = {};
    my $open_section = 0;
    my $last_tag;
    my $debconf = $flags & DCTRL_DEBCONF_TEMPLATE;

    local $_;
    while (<$CONTROL>) {
        chomp;

        # FIXME: comment lines are only allowed in debian/control and should
        # be an error for other control files.
        if (/^\#/) {
            next unless $flags & DCTRL_NO_COMMENTS;
            die "syntax error at line $.: Comments are not allowed.\n";
        }

        # empty line?
        if ((!$debconf && m/^\s*$/) or ($debconf && $_ eq '')) {
            if ($open_section) { # end of current section
                # pass the current section to the handler
                $code->($section, $sline);
                $section = {};
                $open_section = 0;
            }
        }
        # pgp sig?
        elsif (m/^-----BEGIN PGP SIGNATURE/) { # skip until end of signature
            while (<$CONTROL>) {
                last if m/^-----END PGP SIGNATURE/o;
            }
        }
        # other pgp control?
        elsif (m/^-----BEGIN PGP/) { # skip until the next blank line
            while (<$CONTROL>) {
                last if /^\s*$/o;
            }
        }
        # new empty field?
        elsif (m/^([^: \t]+):\s*$/o) {
            $sline = $. if not $open_section;
            $open_section = 1;

            my ($tag) = (lc $1);
            $section->{$tag} = '';

            $last_tag = $tag;
        }
        # new field?
        elsif (m/^([^: \t]+):\s*(.*)$/o) {
            $sline = $. if not $open_section;
            $open_section = 1;

            # Policy: Horizontal whitespace (spaces and tabs) may occur
            # immediately before or after the value and is ignored there.
            my ($tag,$value) = (lc $1,$2);
            $value =~ s/\s+$//;
            if (exists $section->{$tag}) {
                # Policy: A paragraph must not contain more than one instance
                # of a particular field name.
                die "syntax error at line $.: Duplicate field $tag.\n";
            }
            $section->{$tag} = $value;

            $last_tag = $tag;
        }
        # continued field?
        elsif (m/^([ \t].*\S.*)$/o) {
            $open_section or die "syntax error at line $.: Continuation line outside a paragraph.\n";

            # Policy: Many fields' values may span several lines; in this case
            # each continuation line must start with a space or a tab.  Any
            # trailing spaces or tabs at the end of individual lines of a
            # field value are ignored.
            my $value = $1;
            $value =~ s/\s+$//;
            $section->{$last_tag} .= "\n" . $value;
        }
        # None of the above => syntax error
        else {
            my $message = "syntax error at line $.";
            if (m/^\s+$/) {
                $message .= ": Whitespace line not allowed (possibly missing a \".\").\n";
            } else {
                # Replace non-printables and non-space characters with "_"... just in case.
                s/[^[:graph:][:space:]]/_/go;
                $message .= ": Cannot parse line \"$_\"\n";
            }
            die $message;
        }
    }
    # pass the last section (if not already done).
    $code->($section, $sline) if $open_section;
}

=item read_dpkg_control (FILE[, FLAGS[, LINES]])

This is a convenience function to ease using L</parse_dpkg_control>
with paths to files (rather than open handles).  The first argument
must be the path to a FILE, which should be read as a debian control
file.  If the file does not exist (or is empty), an empty list is
returned.

Otherwise, this behaves like:

 open my $fd, '<' FILE or die ...;
 my @p = parse_dpkg_control ($fd, FLAGS, LINES);
 close $fd;
 return @p;

This goes without saying that may fail with any of the messages that
L</parse_dpkg_control> do.  It can also emit the following error:

 "cannot open %s: %s"

=cut

sub read_dpkg_control {
    my ($file, $flags, $lines) = @_;

    if (not _ensure_file_is_sane($file)) {
        return;
    }

    open my $CONTROL, '<', $file or die "cannot open $file: $!";
    my @data = parse_dpkg_control($CONTROL, $flags, $lines);
    close $CONTROL;

    return @data;
}

=item get_deb_control (DEBFILE)

Extracts the control file from DEBFILE and returns it as a hashref.

Basically, this is a fancy convenience for setting up an ar + tar pipe
and passing said pipe to L<parse_dpkg_control>.

If DEBFILE does not exists (or is empty), the empty list is returned.

Note: the control file is only expected to have a single paragraph and
thus only the first is returned (in the unlikely case that there are
more than one).

This function may fail with any of the messages that
L</parse_dpkg_control> do.  It can also emit:

 "cannot fork to unpack %s: %s\n"

=cut

sub get_deb_info {
    my ($file) = @_;

    if (not _ensure_file_is_sane($file)) {
        return;
    }

    # dpkg-deb -f $file is very slow. Instead, we use ar and tar.
    my $opts = { pipe_out => FileHandle->new };
    spawn($opts,
          ['ar', 'p', $file, 'control.tar.gz'],
          '|', ['tar', '--wildcards', '-xzO', '-f', '-', '*control'])
        or die "cannot fork to unpack $file: $opts->{exception}\n";
    my @data = parse_dpkg_control($opts->{pipe_out});

    # Consume all data before exiting so that we don't kill child processes
    # with SIGPIPE.  This will normally only be an issue with malformed
    # control files.
    1 while readline $opts->{pipe_out};
    $opts->{harness}->finish();
    return $data[0];
}

=item get_dsc_control (DSCFILE)

Convenience function for reading dsc files.  It will read the DSCFILE
using L</read_dpkg_control> and then return the first paragraph.  If
the file has no paragraphs, C<undef> is returned instead.

Note: the control file is only expected to have a single paragraph and
thus only the first is returned (in the unlikely case that there are
more than one).

This function may fail with any of the messages that
L</read_dpkg_control> do.

=cut

sub get_dsc_info {
    my ($file) = @_;
    my @data = read_dpkg_control($file);
    return (defined($data[0])? $data[0] : undef);
}

sub _ensure_file_is_sane {
    my ($file) = @_;

    # if file exists and is not 0 bytes
    if (-f $file and -s $file) {
        return 1;
    }
    return 0;
}

=item slurp_entire_file (FOH[, NOCLOSE])

Reads the contents of FOH into memory and return it as a scalar.  FOH
can be either the path to a file or an open file handle.

If it is a handle, the optional NOCLOSE parameter can be used to
prevent the sub from closing the handle.  The NOCLOSE parameter has no
effect if FOH is not a handle.

=cut

sub slurp_entire_file {
    my ($file, $noclose) = @_;
    my $fd;
    my $res;
    if (openhandle $file) {
        $fd = $file;
    } else {
        open $fd, '<', $file
            or fail ("cannot open file $file for reading: $!");
    }
    local $/;
    local $_ = <$fd>;
    close $fd unless $noclose && openhandle $file;
    return $_;
}

=item get_file_checksum (ALGO, FILE)

Returns a hexadecimal string of the message digest checksum generated
by the algorithm ALGO on FILE.

ALGO can be 'md5' or shaX, where X is any number supported by
L<Digest::SHA> (e.g. 'sha256').

This sub is a convenience wrapper around Digest::{MD5,SHA}.

=cut

sub get_file_checksum {
    my ($alg, $file) = @_;
    open (FILE, '<', $file) or fail("Couldn't open $file");
    my $digest;
    if ($alg eq 'md5') {
        $digest = Digest::MD5->new;
    } elsif ($alg =~ /sha(\d+)/) {
        require Digest::SHA;
        $digest = Digest::SHA->new($1);
    }
    $digest->addfile(*FILE);
    close FILE or fail("Couldn't close $file");
    return $digest->hexdigest;
}

=item file_is_encoded_in_non_utf8 (...)

Undocumented

=cut

sub file_is_encoded_in_non_utf8 {
    my ($file, $type, $pkg) = @_;
    my $non_utf8 = 0;

    open (ICONV, '<', $file)
        or fail("failure while checking encoding of $file for $type package $pkg");
    my $line = 0;
    while (<ICONV>) {
        if (m,\e[-!"\$%()*+./],) {
            # ISO-2022
            $line = $.;
            last;
        }
        eval {
            $_ = Encode::decode('UTF-8', $_, Encode::FB_CROAK);
        };
        if ($@) {
            $line = $.;
            last;
        }
    }
    close ICONV;

    return $line;
}

=item system_env (CMD)

Behaves like system (CMD) except that the environment of CMD is
cleaned (as defined by L</clean_env>(1)).

=cut

sub system_env {
    my $pid = fork;
    if (not defined $pid) {
        return -1;
    } elsif ($pid == 0) {
        clean_env(1);
        exec @_ or die("exec of $_[0] failed: $!\n");
    } else {
        waitpid $pid, 0;
        return $?;
    }
}

=item clean_env ([CLOC])

Destructively cleans %ENV - removes all variables %ENV except a
selected few whitelisted variables.

The list of whitelisted %ENV variables are:

 PATH
 INTLTOOL_EXTRACT
 LOCPATH
 LC_ALL (*)

(*) LC_ALL is a special case as clean_env will change its value using
the following rules:


If CLOC is given (and a truth value), clean_env will set LC_ALL to
"C".

Otherwise, clean_env sets LC_ALL to "C.UTF-8" or "en_US.UTF-8" by
checking for the presence of the following paths (in preferred order):

 $ENV{LOCPATH}/C.UTF-8
 $ENV{LOCPATH}/en_US.UTF-8
 /usr/lib/locale/C.UTF-8
 /usr/lib/locale/en_US.UTF-8

If none of these exists, LC_ALL is set to en_US.UTF-8 (as locales-all
provides that locale without creating any paths in /usr/lib/locaale).

=cut

sub clean_env {
    my ($cloc) = @_;
    my @whitelist = qw(PATH INTLTOOL_EXTRACT LOCPATH);
    my @locales = qw(C.UTF-8 en_US.UTF-8);
    my %newenv = map { exists $ENV{$_} ? ($_ => $ENV{$_}) : () } (@whitelist, @_);
    %ENV = %newenv;

    if ($cloc) {
        $ENV{LC_ALL} = 'C';
        return;
    }

    foreach my $locpath ($ENV{LOCPATH}, '/usr/lib/locale') {
        if ($locpath && -d $locpath) {
            foreach my $loc (@locales) {
                if ( -d "$locpath/$loc" ) {
                    $ENV{LC_ALL} = $loc;
                    return;
                }
            }
        }
    }
    # We could not find any valid locale so far - presumably we get our locales
    # from "locales-all", so just set it to "en_US.UTF-8".
    # (related bug: #663459)
    $ENV{LC_ALL} = 'en_US.UTF-8';
}

=item perm2oct (PERM)

Translates PERM to an octal permission.  PERM should be a string describing
the permissions as done by I<tar t> or I<ls -l>.  That is, it should be a
string like "-rwr--r--".

Note, there is no sanity checking of PERM and "unknown" permissions
are silently ignored (as if they had been "-").  Thus, callers should
be fairly certain that PERM is indeed a permission string - otherwise,
this will cause the "garbage in, garbage out" effect.

Examples:

 # Good
 perm2oct ('-rw-r--r--') == 0644
 perm2oct ('-rwxr-xr-x') == 0755

 # Bad
 perm2oct ('broken') == 0000  # too short to be recognised
 perm2oct ('aresurunet') == 05101 # read as "-r-s-----t"

=cut

sub perm2oct {
    my ($t) = @_;

    my $o = 0;

    if ($t !~ m/^.(.)(.)(.)(.)(.)(.)(.)(.)(.)/o) {
        return 0;
    }

    $o += 00400 if $1 eq 'r';   # owner read
    $o += 00200 if $2 eq 'w';   # owner write
    $o += 00100 if $3 eq 'x';   # owner execute
    $o += 04000 if $3 eq 'S';   # setuid
    $o += 04100 if $3 eq 's';   # setuid + owner execute
    $o += 00040 if $4 eq 'r';   # group read
    $o += 00020 if $5 eq 'w';   # group write
    $o += 00010 if $6 eq 'x';   # group execute
    $o += 02000 if $6 eq 'S';   # setgid
    $o += 02010 if $6 eq 's';   # setgid + group execute
    $o += 00004 if $7 eq 'r';   # other read
    $o += 00002 if $8 eq 'w';   # other write
    $o += 00001 if $9 eq 'x';   # other execute
    $o += 01000 if $9 eq 'T';   # stickybit
    $o += 01001 if $9 eq 't';   # stickybit + other execute

    return $o;
}

=item delete_dir (ARGS)

Convient way of calling I<rm -fr ARGS>.

=cut

sub delete_dir {
    return spawn(undef, ['rm', '-rf', '--', @_]);
}

=item copy_dir (ARGS)

Convient way of calling I<cp -a ARGS>.

=cut

sub copy_dir {
    return spawn(undef, ['cp', '-a', '--', @_]);
}

=item gunzip_file (IN, OUT)

Decompresses contents of the file IN and stores the contents in the
file OUT.  IN is I<not> removed by this call.

=cut

sub gunzip_file {
    my ($in, $out) = @_;
    spawn({out => $out, fail => 'error'},
          ['gzip', '-dc', $in]);
}

=item touch_File (FILE)

Updates the "mtime" of FILE.  If FILE does not exist, it will be
created.

Returns 1 on success and 0 on failure.  On failure, $! will contain
the failure.

=cut

sub touch_file {
    my ($file) = @_;
    # We use '>>' because '>' truncates the file if it has contents
    # (which `touch file` doesn't).
    open my $fd, '>>', $file or return 0;
    close $fd or return 0;
    # open with '>>' does not update the mtime if the file already
    # exists, so use utime to solve that.
    utime undef, undef, $file or return 0;

    return 1;
}

=item fail (MSG)

Use to signal an internal error.  MSG will be a diagnostic printed to
the user.

=cut

sub fail {
    my $str;
    if (@_) {
        $str = string('internal error', @_);
    } elsif ($!) {
        $str = string('internal error', $!);
    } else {
        $str = string('internal error');
    }
    $! = 2; # set return code outside eval()
    die $str;
}

=item check_path (CMD)

Returns 1 if CMD can be found in PATH (i.e. $ENV{PATH}) and is
executable.  Otherwise, the function return 0.

=cut

sub check_path {
    my $command = shift;

    return 0 unless exists $ENV{PATH};
    for my $element (split ':', $ENV{PATH}) {
        next unless length $element;
        return 1 if -f "$element/$command" and -x _;
    }
    return 0;
}

=item resolve_pkg_path (CURDIR, DEST)

Using $CURDIR as current directory from the (package) root,
resolve DEST and return (the absolute) path to the destination.
Note that the result will never start with a slash, even if
CURDIR or DEST does. Nor will it end with a slash.

Note it will return '.' if the result is the package root.

Returns a non-truth value, if it cannot safely resolve the path
(e.g. DEST would be outside the package root).

Examples:

  resolve_pkg_path('/usr/share/java', '../ant/file') eq  'usr/share/ant/file'
  resolve_pkg_path('/usr/share/java', '../../../usr/share/ant/file') eq  'usr/share/ant/file'
  resolve_pkg_path('/', 'usr/..') eq '.';

 The following will give a non-truth result:
  resolve_pkg_path('/usr/bin', '../../../../etc/passwd')
  resolve_pkg_path('/usr/bin', '/../etc/passwd')

=cut

sub resolve_pkg_path {
    my ($curdir, $dest) = @_;
    my (@cc, @dc);
    my $target;
    $dest =~ s,//++,/,o;
    # short curcuit $dest eq '/' case.
    return '.' if $dest eq '/';
    # remove any initial ./ and trailing slashes.
    $dest =~ s,^\./,,o;
    $dest =~ s,/$,,o;
    if ($dest =~ m,^/,o){
        # absolute path, strip leading slashes and resolve
        # as relative to the root.
        $dest =~ s,^/,,o;
        return resolve_pkg_path('/', $dest);
    }

    # clean up $curdir (as well)
    $curdir =~ s,//++,/,o;
    $curdir =~ s,/$,,o;
    $curdir =~ s,^/,,o;
    $curdir =~ s,^\./,,o;
    # Short circuit the '.' (or './' -> '') case.
    if ($dest eq '.' or $dest eq '') {
        $curdir =~ s,^/,,o;
        return '.' unless $curdir;
        return $curdir;
    }
    # Relative path from src
    @dc = split(m,/,o, $dest);
    @cc = split(m,/,o, $curdir);
    # Loop through @dc and modify @cc so that in the
    # end of the loop, @cc will contain the path that
    # - note that @cc will be empty if we end in the
    # root (e.g. '/' + 'usr' + '..' -> '/'), this is
    # fine.
    while ($target = shift @dc) {
        if($target eq '..') {
            # are we out of bounds?
            return '' unless @cc;
            # usr/share/java + '..' -> usr/share
            pop @cc;
        } else {
            # usr/share + java -> usr/share/java
            push @cc, $target;
        }
    }
    return '.' unless @cc;
    return join '/', @cc;
}

=back

=head1 SEE ALSO

lintian(1)

=cut

1;

# Local Variables:
# indent-tabs-mode: nil
# cperl-indent-level: 4
# End:
# vim: syntax=perl sw=4 sts=4 sr et
