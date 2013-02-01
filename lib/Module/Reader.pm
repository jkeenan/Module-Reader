package Module::Reader;
BEGIN { require 5.006 }
use strict;
use warnings;

our $VERSION = '0.00100';
$VERSION = eval $VERSION;

use base 'Exporter';
our @EXPORT = qw(module_content module_handle);

use File::Spec;
use Scalar::Util qw(blessed reftype openhandle);
use Carp;
use constant _OPEN_STRING => $] >= 5.008;
BEGIN {
    require IO::String
        if !_OPEN_STRING;
}

sub module_content {
    my $module = _get_module(@_);
    if (ref $module) {
        local $/;
        return scalar <$module>;
    }
    else {
        return $module;
    }
}

sub module_handle {
    my $module = _get_module(@_);
    if (ref $module) {
        return $module;
    }
    elsif (_OPEN_STRING) {
        open my $fh, '<', \$module;
        return $fh;
    }
    else {
        return IO::String->new($module);
    }
}

sub _get_module {
    my ($package, @inc) = @_;
    (my $module = "$package.pm") =~ s{::}{/}g;
    if (!@inc) {
        @inc = @INC;
    }
    for my $inc (@inc) {
        if (!ref $inc) {
            my $full_module = File::Spec->catfile($inc, $module);
            next unless -f $full_module;
            open my $fh, '<', $full_module
                or die "Couldn't open ${full_module} for ${module}: $!";
            return $fh;
        }

        my @cb = ref $inc eq 'ARRAY'  ? $inc->[0]->($inc, $module)
               : blessed $inc         ? $inc->INC($module)
                                      : $inc->($inc, $module);

        next
            unless ref $cb[0];
        my $fh;
        if (reftype $cb[0] eq 'GLOB' && openhandle $cb[0]) {
            $fh = shift @cb;
        }

        if (ref $cb[0] eq 'CODE') {
            my $cb = shift @cb;
            # require docs are wrong, perl sends 0 as the first param
            my @params = (0, @cb ? $cb[0] : ());

            my $module = '';
            while (1) {
                local $_ = $fh ? <$fh> : '';
                $_ = ''
                    if !defined;
                last if !$cb->(@params);
                $module .= $_;
            }
            return $module;
        }
        elsif ($fh) {
            return $fh;
        }
    }
    croak "Can't find module $module";
}

1;

__END__

=head1 NAME

Module::Reader - Read the source of a module like perl does

=head1 SYNOPSIS

    use Module::Reader;
    my $io = module_handle('My::Module');
    my $content = module_content('My::Module');

=head1 DESCRIPTION

Reads the content of perl modules the same way perl does.  This
includes reading modules available only by C<@INC> hooks, or filtered
through them.

=head1 EXPORTS

=head2 module_handle( $module_name )

Returns an IO handle to the given module.

=head2 module_content( $module_content )

Returns the content of the given module.

=head1 AUTHOR

haarg - Graham Knop (cpan:HAARG) <haarg@haarg.org>

=head2 CONTRIBUTORS

None yet.

=head1 COPYRIGHT

Copyright (c) 2013 the App::FatPacker L</AUTHOR> and L</CONTRIBUTORS>
as listed above.

=head1 LICENSE

This library is free software and may be distributed under the same terms
as perl itself.

=cut