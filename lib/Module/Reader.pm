package Module::Reader;
BEGIN { require 5.006 }
use strict;
use warnings;

our $VERSION = '0.002003';
$VERSION = eval $VERSION;

use Exporter (); *import = \&Exporter::import;
our @EXPORT_OK = qw(module_content module_handle);
our %EXPORT_TAGS = (all => [@EXPORT_OK]);

use File::Spec;
use Scalar::Util qw(blessed reftype refaddr openhandle);
use Carp;
use Config ();
use Errno qw(EACCES);
use constant _PMC_ENABLED => !(
  exists &Config::non_bincompat_options ? grep { $_ eq 'PERL_DISABLE_PMC' } Config::non_bincompat_options()
  : $Config::Config{ccflags} =~ /(?:^|\s)-DPERL_DISABLE_PMC\b/
);
use constant _VMS => $^O eq 'VMS' && !!require VMS::Filespec;
use constant _WIN32 => $^O eq 'MSWin32';
use constant _FAKE_FILE_FORMAT => do {
  (my $uvx = $Config::Config{uvxformat}||'') =~ tr/"//d;
  $uvx ||= 'lx';
  "/loader/0x%$uvx/%s"
};

sub _mod_to_file {
  my $module = shift;
  (my $file = "$module.pm") =~ s{::}{/}g;
  $file;
}

sub module_content {
  my $opts = ref $_[-1] eq 'HASH' && pop @_ || {};
  my $module = shift;
  $opts->{inc} = [@_]
    if @_;
  __PACKAGE__->new($opts)->module($module)->content;
}

sub module_handle {
  my $opts = ref $_[-1] eq 'HASH' && pop @_ || {};
  my $module = shift;
  $opts->{inc} = [@_]
    if @_;
  __PACKAGE__->new($opts)->module($module)->handle;
}

sub new {
  my $class = shift;
  my %options;
  if (@_ == 1 && ref $_[-1]) {
    %options = %{(pop)};
  }
  elsif (@_ % 2 == 0) {
    %options = @_;
  }
  else {
    croak "Expected hash ref, or key value pairs.  Got ".@_." arguments.";
  }

  $options{inc} ||= \@INC;
  $options{found} = \%INC
    if exists $options{found} && $options{found} eq 1;
  $options{pmc} = _PMC_ENABLED
    if !exists $options{pmc};
  bless \%options, $class;
}

sub module {
  my ($self, $module) = @_;
  $self->file(_mod_to_file($module));
}

sub modules {
  my ($self, $module) = @_;
  $self->files(_mod_to_file($module));
}

sub file {
  my ($self, $file) = @_;
  $self->_find($file);
}

sub files {
  my ($self, $file) = @_;
  $self->_find($file, 1);
}

sub _searchable {
  my $file = shift;
    File::Spec->file_name_is_absolute($file) ? 0
  : _WIN32 && $file =~ m{^\.\.?[/\\]}        ? 0
  : $file =~ m{^\.\.?/}                      ? 0
                                             : 1
}

sub _find {
  my ($self, $file, $all) = @_;

  if (!_searchable($file)) {
    my $open = _open_file($file);
    return $open
      if $open;
    croak "Can't locate $file";
  }

  my @found;
  eval {
    if (my $found = $self->{found}) {
      if (defined( my $full = $found->{$file} )) {
        my $open = length ref $full ? $self->_open_ref($full, $file)
                                    : $self->_open_file($full, $file);
        push @found, $open
          if $open;
      }
    }
  };
  if (!$all) {
    return $found[0]
      if @found;
    die $@
      if $@;
  }
  my $search = $self->{inc};
  for my $inc (@$search) {
    my $open;
    eval {
      if (!length ref $inc) {
        my $full = _VMS ? VMS::Filespec::unixpath($inc) : $inc;
        $full =~ s{/?$}{/};
        $full .= $file;
        $open = $self->_open_file($full, $file, $inc);
      }
      else {
        $open = $self->_open_ref($inc, $file);
      }
      push @found, $open
        if $open;
    };
    if (!$all) {
      return $found[0]
        if @found;
      die $@
        if $@;
    }
  }
  croak "Can't locate $file"
    if !$all;
  return @found;
}

sub _open_file {
  my ($self, $full, $file, $inc) = @_;
  for my $try (
    ($self->{pmc} && $file =~ /\.pm\z/ ? $full.'c' : ()),
    $full,
  ) {
    my $pmc = $full eq $try;
    next
      if -e $try ? (-d _ || -b _) : $! != EACCES;
    my $fh;
    open $fh, '<:', $try
      and return Module::Reader::File->new(
        filename        => $file,
        raw_filehandle  => $fh,
        found_file      => $full,
        disk_file       => $try,
        is_pmc          => $pmc,
        (defined $inc ? (inc_entry => $inc) : ()),
      );
    croak "Can't locate $file:   $full: $!"
      if $pmc;
  }
  return;
}

sub _open_ref {
  my ($self, $inc, $file) = @_;

  my @cb = defined blessed $inc ? $inc->INC($file)
         : ref $inc eq 'ARRAY'  ? $inc->[0]->($inc, $file)
                                : $inc->($inc, $file);

  return
    unless length ref $cb[0];

  my $fake_file = sprintf _FAKE_FILE_FORMAT, refaddr($inc), $file;

  my $fh;
  my $cb;
  my $cb_options;

  if (reftype $cb[0] eq 'GLOB' && openhandle $cb[0]) {
    $fh = shift @cb;
  }

  if ((reftype $cb[0]||'') eq 'CODE') {
    $cb = $cb[0];
    $cb_options = @cb > 1 ? [ $cb[1] ] : undef;
  }
  elsif (!$fh) {
    return;
  }
  return Module::Reader::File->new(
    filename => $file,
    found_file => $fake_file,
    inc_entry => $inc,
    (defined $fh ? (raw_filehandle => $fh) : ()),
    (defined $cb ? (read_callback => $cb) : ()),
    (defined $cb_options ? (read_callback_options => $cb_options) : ()),
  );
}

{
  package Module::Reader::File;
  use constant _OPEN_STRING => "$]" >= 5.008 || (require IO::String, 0);

  sub new {
    my ($class, %opts) = @_;
    my $filename = $opts{filename};
    if (!exists $opts{module} && $opts{filename}
      && $opts{filename} =~ m{\A(\w+(?:/\w+)?)\.pm\z}) {
      my $module = $1;
      $module =~ s{/}{::}g;
      $opts{module} = $module;
    }
    bless \%opts, $class;
  }

  sub filename              { $_[0]->{filename} }
  sub module                { $_[0]->{module} }
  sub raw_filehandle        { $_[0]->{raw_filehandle} }
  sub found_file            { $_[0]->{found_file} }
  sub disk_file             { $_[0]->{disk_file} }
  sub is_pmc                { $_[0]->{is_pmc} }
  sub inc_entry             { $_[0]->{inc_entry} }
  sub read_callback         { $_[0]->{read_callback} }
  sub read_callback_options { $_[0]->{read_callback_options} }

  sub content {
    my $self = shift;
    my $fh = $self->raw_filehandle;
    my $cb = $self->read_callback;
    if ($fh && !$cb) {
      local $/;
      return scalar <$fh>;
    }
    my @params = @{$self->read_callback_options||[]};
    my $content = '';
    while (1) {
      local $_ = $fh ? <$fh> : '';
      $_ = ''
        if !defined;
      last if !$cb->(0, @params);
      $content .= $_;
    }
    return $content;
  }

  sub handle {
    my $self = shift;
    my $fh = $self->raw_filehandle;
    return $fh
      if $fh && !$self->read_callback;
    my $content = $self->content;
    if (_OPEN_STRING) {
      open my $fh, '<', \$content;
      return $fh;
    }
    else {
      return IO::String->new($content);
    }
  }
}

1;

__END__

=head1 NAME

Module::Reader - Find and read perl modules like perl does

=head1 SYNOPSIS

  use Module::Reader;

  my $reader      = Module::Reader->new;
  my $module      = $reader->module("My::Module");
  my $filename    = $module->found_file;
  my $content     = $module->content;
  my $file_handle = $module = $module->handle;

  # search options
  my $other_reader = Module::Reader->new(inc => ["/some/lib/dir", "/another/lib/dir"]);
  my $other_reader2 = Module::Reader->new(found => { 'My/Module.pm' => '/a_location.pm' });

  # Functional Interface
  use Module::Reader qw(module_handle module_content);
  my $io = module_handle('My::Module');
  my $content = module_content('My::Module');


=head1 DESCRIPTION

This module finds modules in C<@INC> using the same algorithm perl does.  From
that, it will give you the source content of a module, the file name (where
available), and how it was found.  Searches (and content) are based on the same
internal rules that perl uses for F<perlfunc/require> and F<perlfunc/do>.

=head1 EXPORTS

=head2 module_handle ( $module_name, @search_directories )

Returns an IO handle for the given module.

=head2 module_content ( $module_name, @search_directories )

Returns the content of a given module.

=head1 CLASS ATTRIBUTES

=over 4

=item inc

An array reference containing a list of directories or hooks to search for
modules or files.  This will be used in the same manner that L<perlfunc/require>
uses L<perlvar/@INC>.  If not provided, L<perlvar/@INC> itself will be used.

=item found

A hash reference of module filenames (of C<My/Module.pm> format>) to files that
exist on disk, working the same as F<%INC/perlvar>.  The values can optionally
be an F<C<@INC> hook|perlvar/@INC>.  This option can also be 1, in which case
L<perlfunc/%INC> will be used instead.

=item pmc

A boolean controlling if C<.pmc> files should be found in preference to C<.pm>
files.  If not specified, the same behavior perl was compiled with will be used.

=back

=head1 METHODS

=head2 module

Returns a L<file object|/FILE OBJECTS> for the given module name.  If the module
can't be found, an exception will be raised.

=head2 file

Returns a L<file object|/FILE OBJECTS> for the given file name.  If the file
can't be found, an exception will be raised.  For files starting with C<./> or
C<../>, no directory search will be performed.

=head2 modules

Returns an array of L<file objects|/FILE OBJECTS> for a given module name.  This
will give every file that could be loaded based on the L</inc> options.

=head2 files

Returns an array of L<file objects|/FILE OBJECTS> for a given file name.  This
will give every file that could be loaded based on the L</inc> options.

=head1 FILE OBJECTS

The file objects returned represent an entry that could be found in
L<perlfunc/@INC>.  While they will generally be files that exist on the file
system somewhere, they may also represent files that only exist only in memory
or have arbitrary filters applied.

=head2 FILE METHODS

=head3 filename

The filename that was seached for.

=head3 module

If a module was searched for, or a file of the matching form (C<My/Module.pm>),
this will be the module searched for.

=head3 found_file

The path to the file found by L<perlfunc/require>.

This may not represent an actual file that exists, but the file name that perl
is using for the file for things like L<perlfunc/caller> or L<perlfunc/__FILE__>.

For C<.pmc> files, this will be the C<.pm> form of the file.

For L<@INC hooks|perlfunc/require> this will be a file name of the form
C</loader/0x123456abcdef/My/Module.pm>, matching how perl treats them internally.

=head3 disk_file

The path to the file that exists on disk.  When the file is found via an
L<@INC hook|perlfunc/require>, this will be undef.

=head3 is_pnc

A boolean value representing if the file found was C<.pmc> variant of the file
requested.

=head3 inc_entry

The directory or L<hook|perlfunc/require> that was used to find the given file
or module.  IF L</found> is used, this may be undef.

=head3 raw_filehandle

The raw file handle to the file found.  This will be either a file handle to a
file on disk, or something returned by an F<@INC hook|perlfunc/require>.  This
should only be used by code intending to interrogate
L<@INC hooks|perlfunc/require>.

=head3 read_callback

A callback meant to be used to read or modify content from an
F<@INC hook|perlfunc/require> for the file handle.

=head3 read_callback_options

The arguments to be sent to the read callback for modifying content from an
F<@INC hook|perlfunc/require> for the file handle.

=head1 SEE ALSO

Numerous other modules attempt to do C<@INC> searches similar to this module,
but no other module accurately represents how perl itself uses L<perlvar/@INC>.

Some of these modules have other use cases.  The following comments are
primarily related to their ability to search C<@INC>.

=over 4

=item L<App::moduleswhere>

Only available as a command line utility.  Inaccurately gives the first file
found on disk in C<@INC>.

=item L<App::whichpm>

Inaccurately gives the first file found on disk in C<@INC>.

=item L<Class::Inspector>

For unloaded modules, inaccurately checks if a module exists.

=item L<Module::Data>

Same caveats as L</Path::ScanINC>.

=item L<Module::Filename>

Inaccurately gives the first file found on disk in C<@INC>.

=item L<Module::Finder>

Inaccurately searches for C<.pm> and C<.pmc> files in subdirectories of C<@INC>.

=item L<Module::Info>

Inaccurately searches C<@INC> for files and gives inaccurate information for the
files that it finds.

=item L<Module::Locate>

Innacurately searches C<@INC> for matching files.  Attempts to handle hooks, but
handles most cases wrong.

=item L<Module::Mapper>

Searches for C<.pm> and C<.pod> files in relatively unpredictable fashion,
based usually on the current directory.  Optionally, can inaccurately scan
C<@INC>.

=item L<Module::Metadata>

Primarily designed as a version number extractor.  Meant to find files on disk,
avoiding the nuance involved in perl's file loading.

=item L<Module::Path>

Inaccurately gives the first file found on disk in C<@INC>.

=item L<Module::Util>

Inaccurately searches for modules, ignoring C<@INC> hooks.

=item L<Path::ScanINC>

Inaccurately searches for files, with confusing output for C<@INC> hooks.

=item L<Pod::Perldoc>

Primarily meant for searching for related documentation.  Finds related module
files, or sometimes C<.pod> files.  Unpredictable search path.

=back

=head1 AUTHOR

haarg - Graham Knop (cpan:HAARG) <haarg@haarg.org>

=head2 CONTRIBUTORS

None yet.

=head1 COPYRIGHT

Copyright (c) 2013 the Module::Reader L</AUTHOR> and L</CONTRIBUTORS>
as listed above.

=head1 LICENSE

This library is free software and may be distributed under the same terms
as perl itself.

=cut
