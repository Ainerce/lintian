# Lintian::Lab::Manifest -- Lintian Lab manifest

# Copyright (C) 2011 Niels Thykier
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

package Lintian::Lab::Manifest;

use strict;
use warnings;

use base qw(Class::Accessor);

use Carp qw(croak);

=head1 NAME

Lintian::Lab::Manifest -- Lintian Lab manifest

=head1 SYNOPSIS

 use Lintian::Lab::Manifest;
 
 my $plist = Lintian::Lab::Manifest->new ('binary');
 # Read the file
 $plist->read_list('info/binary-packages');
 # fetch the entry for lintian (if any)
 my $entry = $plist->get('lintian', '2.5.2', 'all');
 if ( $entry && exits $entry->{'version'} ) {
    print "Lintian has version $entry->{'version'}\n";
 }
 # delete all lintian entries
 $plist->delete('lintian');
 # Write to file if changed
 if ($plist->dirty) {
    $plist->write_list('info/binary-packages');
 }

=head1 DESCRIPTION

Instances of this class provides access to the packages list used by
the Lab as caches.

The data structure is basically a tree (using hashes).  For binaries
is looks (something) like:

 $self->{'state'}->{$name}->{$version}->{$architecture}

The (order of the) fields used in the tree is listed in the
@{BIN,SRC,CHG}_QUERY lists below.  The fields may (and generally do)
differ between package types.

=head1 METHODS

=over 4

=cut

# these banner lines have to be changed with every incompatible change of the
# binary and source list file formats
use constant BINLIST_FORMAT => "Lintian's list of binary packages in the archive--V5";
use constant SRCLIST_FORMAT => "Lintian's list of source packages in the archive--V5";
use constant CHGLIST_FORMAT => "Lintian's list of changes packages in the archive--V1";

# List of fields in the formats and the order they appear in
#  - for internal usage to read and write the files

# source package lists
my @SRC_FILE_FIELDS = (
    'source',
    'version',
    'maintainer',
    'uploaders',
    'area',
    'binary',
    'file',
    'timestamp',
);

# binary/udeb package lists
my @BIN_FILE_FIELDS = (
    'package',
    'version',
    'source',
    'source-version',
    'architecture',
    'file',
    'timestamp',
    'area',
);

# changes packages lists
my @CHG_FILE_FIELDS = (
    'source',
    'version',
    'architecture',
    'file',
    'timestamp',
);

# List of fields (in order) of fields used to look up the package in the
# manifest.  The field names matches those used in the list above.

my @SRC_QUERY = (
    'source',
    'version',
);

my @BIN_QUERY = (
    'package',
    'version',
    'architecture',
);

my @CHG_QUERY = (
    'source',
    'version',
    'architecture',
);

=item Lintian::Lab::Manifest->new ($pkg_type)

Creates a new packages list for a certain type of packages.  This type
defines the format of the files.

The known types are:
 * binary
 * changes
 * source
 * udeb

=cut

sub new {
    my ($class, $pkg_type) = @_;
    my $self = {
        'type'  => $pkg_type,
        'dirty' => 0,
        'state' => {},
    };
    bless $self, $class;
    return $self;
}

=item $manifest->dirty

Returns a truth value if the manifest has changed since it was last
written.

=item $manifest->type

Returns the type of packages that this manifest has information about.
(one of binary, udeb, source or changes)

=cut


Lintian::Lab::Manifest->mk_ro_accessors (qw(dirty type));

=item $manifest->read_list ($file)

Reads a manifest from $file.  Any records already in the manifest will
be discarded before reading the contents.

On success, this will clear the L<dirty|/dirty> flag and on error it
will croak.

=cut

sub read_list {
    my ($self, $file) = @_;
    my $header;
    my $fields;
    my $qf;

    # Accept a scalar (as an "in-memory file") - write_list does the same
    if (my $r = ref $file) {
        croak "Attempt to pass non-scalar ref to read_list.\n" unless $r eq 'SCALAR';
    } else {
        # FIXME: clear the manifest if -s $file
        return unless -s $file;
    }

    ($header, $fields, $qf) = $self->_type_to_fields;

    $self->{'state'} = $self->_do_read_file($file, $header, $fields, $qf);
    $self->_mark_dirty(0);
    return 1;
}

=item $manifest->write_list ($file)

Writes the manifest to $file.

On success, this will clear the L<dirty|/dirty> flag and on error it
will croak.

On error, the contents of $file is undefined.

=cut

sub write_list {
    my ($self, $file) = @_;
    my ($header, $fields, undef) = $self->_type_to_fields;
    my $visitor;


    open my $fd, '>', $file or croak "open $file: $!";
    print $fd "$header\n";

    $visitor = sub {
        my ($entry) = @_;
        my %values = %$entry;
        print $fd join(';', @values{@$fields}) . "\n";
    };

    $self->visit_all ($visitor);

    close $fd or croak "close $file: $!";
    $self->_mark_dirty(0);
    return 1;
}

=item $manifest->visit_all ($visitor[, $key1, ..., $keyN])

Visits entries and passes them to $visitor.  If any keys are passed they
are used to reduce the search.  See get for a list of (common) keys.

The $visitor is called as:

 $visitor->($entry, @keys)

Where $entry is the entry and @keys are the keys to be used to look up
this entry via get method.  So for the lintian 2.5.2 binary the keys
would be something like:
 ('lintian', '2.5.2', 'all')

=cut

sub visit_all {
    my ($self, $visitor, @keys) = @_;
    my $root;
    my $type = $self->type;
    my (undef, undef, $qf) = $self->_type_to_fields;

    if (@keys) {
        $root = $self->_do_get ($self->{'state'}, @keys);
        return unless $root;
    } else {
        $root = $self->{'state'};
    }

    $self->_recurse_visit ($root, $visitor, scalar @$qf - 1, @keys);
}

=item $manifest->get (@keys)

Fetches the entry for @keys (if any).  Returns C<undef> if the entry
is not known.

The keys are (in general and in order):

 * package/source
 * version
 * architeture (except for source packages)

=cut

sub get {
    my ($self, @keys) = @_;
    return $self->_do_get ($self->{'state'}, @keys);
}

=item $manifest->set ($entry)

Inserts $entry into the manifest.  This may replace an existing entry.

Note: The interesting fields from $entry is copied, so later changes
to $entry will not affect the data in $manifest.

=cut

sub set {
    my ($self, $entry) = @_;
    my %pdata;
    my (undef, $fields, $qf) = $self->_type_to_fields;

    # Copy the relevant fields - ensuring all fields are defined.
    %pdata = map { $_ => $entry->{$_}//'' } @$fields;
    $self->_do_set ($self->{'state'}, $qf, \%pdata);
    $self->_mark_dirty(1);
    return 1;
}

=item $manifest->delete (@keys)

Removes the entry/entries found by @keys (if any).  @keys must contain
at least one item - if the list of keys cannot uniquely identify a single
element, all "matching" elements will be removed.  Examples:

 # Delete the gcc-4.6 entry at version 4.6.1-4 that is also architecture i386
 $manifest->delete ('gcc-4.6', '4.6.1-4', 'i386');
 
 # Delete all gcc-4.6 entries at version 4.6.1-4 regardless of their
 # architecture
 $manifest->delete ('gcc-4.6', '4.6.1-4');
 
 # Delete all gcc-4.6 entries regardless of version and architecture
 $manifest->delete ('gcc-4.6')


This will mark the list as dirty if an element was removed.  If it returns
a truth value, an element was removed - otherwise it will return 0.

See L</$manifest->get (@keys)|get> for the key names.

=cut

sub delete {
    my ($self, @keys) = @_;
    # last key, that is what we will remove :)
    my $lk = pop @keys;
    my $hash;

    return 0 unless defined $lk;

    if (@keys) {
        $hash = $self->_do_get ($self->{'state'}, @keys);
    } else {
        $hash = $self->{'state'};
    }

    if (defined $hash && exists $hash->{$lk}) {
        delete $hash->{$lk};
        $self->_mark_dirty(1);
        return 0;
    }
    return 1;
}

### Internal methods ###

# $plist->_mark_dirty($val)
#
# Internal sub to alter the dirty flag. 1 for dirty, 0 for "not dirty"
sub _mark_dirty {
    my ($self, $dirty) = @_;
    $self->{'dirty'} = $dirty;
}

# $plist->_do_read_file($file, $header, $fields)
#
# internal sub to actually load the pkg list from $file.
# $header is the expected header (first line excl. newline)
# $fields is a ref to the relevant field list (see @*_FILE_FIELDS)
#  - croaks on error
sub _do_read_file {
    my ($self, $file, $header, $fields, $qf) = @_;
    my $count = scalar @$fields;
    my $root = {};
    open my $fd, '<', $file or croak "open $file: $!";
    my $hd = <$fd>;
    chop $hd;
    unless ($hd eq $header) {
        close($fd);
        croak "Unknown/unsupported file format ($hd)";
    }

    while ( my $line = <$fd> ) {
        chop($line);
        next if $line =~ m/^\s*+$/o;
        my (@values) = split m/\;/o, $line, $count;
        my $entry = {};
        unless ($count == scalar @values) {
            close $fd;
            croak "Invalid line in $file at line $. ($_)"
        }
        for ( my $i = 0 ; $i < $count ; $i++) {
            $entry->{$fields->[$i]} = $values[$i]//'';
        }
        $self->_do_set ($root, $qf, $entry);
    }
    close $fd;
    return $root;
}

sub _do_get {
    my ($self, $root, @keys) = @_;
    my $cur = $root;
    foreach my $key (@keys) {
        $cur = $cur->{$key};
        return unless defined $cur;
    }
    return $cur;
}

sub _do_set {
    my ($self, $root, $qf, $entry) = @_;
    my $qfl = scalar @$qf - 1; # exclude the last element (see below)
    my $cur = $root;
    my $k;

    # Find the hash where the entry should be stored
    # - The basic structure is "$root->{key1}->...->{keyN-1}->{keyN} = $entry"
    # - This loop is supposed to find the "n-1"th hash and save that in $cur.
    # - After the loop, a simple "$cur->{$keyN} = $entry" inserts the element.
    for ( my $i = 0 ; $i < $qfl ; $i++) {
        # Current key
        my $curk = $entry->{$qf->[$i]};
        my $element = $cur->{$curk};
        unless (defined $element) {
            $element = {};
            $cur->{$curk} = $element;
        }
        $cur = $element;
    }
    $k = $entry->{$qf->[$qfl]};
    $cur->{$k} = $entry;
    return 1;
}


# Returns ($header, $fields, $qf) - their value is based on $self->type.
# - $header is XXXLIST_FORMAT
# - $fields is \@XXX_FILE_FIELDS
# - $qf     is \@XXX_QUERY
sub _type_to_fields {
    my ($self) = @_;
    my $header;
    my $fields;
    my $qf;
    my $type = $self->{'type'};

    if ($type eq 'source') {
        $fields = \@SRC_FILE_FIELDS;
        $qf = \@SRC_QUERY;
        $header = SRCLIST_FORMAT;
    } elsif ($type eq 'binary' || $type eq 'udeb') {
        $fields = \@BIN_FILE_FIELDS;
        $qf = \@BIN_QUERY;
        $header = BINLIST_FORMAT;
    } elsif ($type eq 'changes') {
        $fields = \@CHG_FILE_FIELDS;
        $qf = \@CHG_QUERY;
        $header = CHGLIST_FORMAT;
    } else {
        croak "Unknown type $type";
    }
    return ($header, $fields, $qf);
}

# Self-recursing method powering visit_all
sub _recurse_visit {
    my ($self, $hash, $visitor, $vdep, @keys) = @_;
    # if false, we recurse, if true we pass it to $visitor
    my $visit = $vdep == scalar @keys;
    foreach my $k (sort keys %$hash) {
        my $v = $hash->{$k};
        # Should we recurse into $v?
        $self->_recurse_visit ($v, $visitor, $vdep, @keys, $k) unless $visit;
        # ... or is it the value to be visited?
        $visitor->($v, @keys, $k) if $visit;
    }
}

=back

=head1 AUTHOR

Originally written by Niels Thykier <niels@thykier.net> for Lintian.

=head1 SEE ALSO

lintian(1)

=cut

1;

# Local Variables:
# indent-tabs-mode: nil
# cperl-indent-level: 4
# End:
# vim: syntax=perl sw=4 sts=4 sr et
