#!/usr/bin/perl -w
# init.d -- lintian collector script

# Copyright (C) 1998 Richard Braakman
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

use strict;
use warnings;

use lib "$ENV{'LINTIAN_ROOT'}/lib";
use Util;

($#ARGV == 1) or fail('syntax: init.d <pkg> <type>');
my $pkg = shift;
my $type = shift;

if (-e 'init.d') {
    delete_dir('init.d')
        or fail('cannot rm old init.d directory');
}

if (-d 'unpacked/etc/init.d') {
    copy_dir('unpacked/etc/init.d', 'init.d')
        or fail('cannot copy init.d directory');
} else {
    # no etc/init.d
    mkdir('init.d', 0777) or fail("cannot mkdir init.d: $!");
}

# Local Variables:
# indent-tabs-mode: nil
# cperl-indent-level: 4
# End:
# vim: syntax=perl sw=4 sts=4 sr et
