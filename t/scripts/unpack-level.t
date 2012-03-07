#!/usr/bin/perl -w

# Copyright (C) 2009 by Raphael Geissert <atomo64@gmail.com>
# Copyright (C) 2009 Russ Allbery <rra@debian.org>
#
# This file is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.
#
# This file is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this file.  If not, see <http://www.gnu.org/licenses/>.

use strict;

use Test::More;
use Util qw(read_dpkg_control slurp_entire_file);

# Find all of the desc files in either collection or checks.  We'll do one
# check per description.
our @DESCS = (<$ENV{LINTIAN_ROOT}/collection/*.desc>,
              <$ENV{LINTIAN_ROOT}/checks/*.desc>);
plan tests => scalar(@DESCS) * 2;

my @l2refs = (
        qr|->unpacked|,
	qr<unpacked/>,
	qr<unpacked-errors>,
	qr<chdir\s*\(\s*["'](?:\$dir/)?unpacked/?['"]\s*\)>,
);

# For each desc file, load the first stanza of the file and check that if
# the unpack level is one no reference to unpack/ should be made, and if
# it is level two then there should be a reference
for my $desc (@DESCS) {
    my ($header) = read_dpkg_control($desc);
    my $level = $header->{'unpack-level'};

    if ($desc =~ m/lintian\.desc$/) {
	ok(!defined($level), "lintian.desc doesn't define unpack-level");
	ok(1, "lintian.desc has valid needs-info for unpack level");
	next;
    }

    my $info = $header->{'needs-info'} || '';
    chomp $info;
    my %ninfo = map {$_ => 1} split(/\s*,\s*/, $info);
    my ($file) = split(/\.desc$/, $desc);
    my $code = slurp_entire_file($file);
    my $requires_unpacked = 0;

    for my $l2ref (@l2refs) {
	if ($code =~ m/$l2ref/) {
	    $requires_unpacked = 1;
	    last;
	}
    }
    my $short = $desc;
    $short =~ s,^\Q$ENV{LINTIAN_ROOT}\E/?,,;

    # it is ok that collection/unpacked doesn't depend on itself :)
    $requires_unpacked = 0 if ($short eq 'collection/unpacked.desc');

    # no script should be using unpack-level: n anymore
    ok(!defined($level), "$short doesn't define unpack-level");

    ok($requires_unpacked? defined($ninfo{'unpacked'}) : !defined($ninfo{'unpacked'}),
	"$short has valid needs-info for unpack level");
}
