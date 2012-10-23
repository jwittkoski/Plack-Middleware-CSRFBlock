package Plack::Middleware::CSRFBlock;
use parent qw(Plack::Middleware);
use strict;
use warnings;
our $VERSION = '0.06';

use HTML::Parser;
use Plack::TempBuffer;
use Plack::Util;
use Plack::Request;
use Digest::SHA1;
use Plack::Util::Accessor qw(
    parameter_name header_name add_meta meta_name token_length
    session_key blocked onetime
    _token_generator _env
);

sub prepare_app {
    my ($self) = @_;

    $self->parameter_name('SEC') unless defined $self->parameter_name;
    $self->token_length(16) unless defined $self->token_length;
    $self->session_key('csrfblock.token') unless defined $self->session_key;
    $self->meta_name('csrftoken') unless defined $self->meta_name;
    $self->add_meta(0) unless defined $self->meta_name;

    # Upper-case header name and replace - with _
    my $header_name = uc($self->header_name || 'X-CSRF-Token') =~ s/-/_/gr;
    # Add 'HTTP_' to beginning, and set the new header_name
    $self->header_name( "HTTP_" . $header_name );


    my $parameter_name = $self->parameter_name;
    my $token_length = $self->token_length;

    $self->_token_generator(sub {
        my $token = Digest::SHA1::sha1_hex(rand() . $$ . {} . time);
        substr($token, 0 , $token_length);
    });
}

sub log {
    my ($self, $level, $msg) = @_;
}

sub call {
    my($self, $env) = @_;

    # Set the env on self
    $self->_env( $env );

    # Generate a Plack Request for this request
    my $request = Plack::Request->new( $env );

    # We need a session
    my $session = $request->session;
    die "CSRFBlock needs Session." unless $session;

    # input filter
    if( $request->method =~ m{^post$}i ) {
        my $token = $session->{$self->session_key}
            or return $self->token_not_found( $env );

        my $found;

        # First, check if the header is set correctly.
        $found = ( $request->header( $self->header_name ) || '') eq $token;

        # If the token wasn't set, let's check the params
        unless ($found) {
            my $val = $request->parameters->{ $self->parameter_name } || '';
            $found = $val eq $token;
        }

        return $self->token_not_found($env) unless $found;

        # If we are using onetime token, remove it from the session
        delete $session->{$self->session_key} if $self->onetime;
    }

    return $self->response_cb($self->app->($env), sub {
        my $res = shift;
        my $ct = Plack::Util::header_get($res->[1], 'Content-Type') || '';
        if($ct !~ m{^text/html}i and $ct !~ m{^application/xhtml[+]xml}i){
            return $res;
        }

        my @out;
        my $http_host = exists $env->{HTTP_HOST} ? $env->{HTTP_HOST} : $env->{SERVER_NAME};
        my $token = $session->{$self->session_key} ||= $self->_token_generator->();
        my $parameter_name = $self->parameter_name;

        my $p = HTML::Parser->new(
            api_version => 3,
            start_h => [sub {
                my($tag, $attr, $text) = @_;
                push @out, $text;

                no warnings 'uninitialized';
                if(
                    lc($tag) eq 'form' and
                    lc($attr->{'method'}) eq 'post' and
                    !($attr->{'action'} =~ m{^https?://([^/:]+)[/:]} and $1 ne $http_host)
                ) {
                    push @out, qq{<input type="hidden" name="$parameter_name" value="$token" />};
                }

                # If we found the head tag and we want to add a <meta> tag
                if( lc($tag) eq 'head' && $self->add_meta ) {
                    # Put the csrftoken in a <meta> element in <head>
                    # So that you can get the token in javascript in your
                    # App to set in X-CSRF-Token header for all your AJAX
                    # Requests
                    my $name = $self->meta_name;
                    push @out, "<meta name=\"$name\" content=\"$token\"/>";
                }

                # TODO: determine xhtml or html?
                return;
            }, "tagname, attr, text"],
            default_h => [\@out , '@{text}'],
        );
        my $done;

        return sub {
            return if $done;

            if(defined(my $chunk = shift)) {
                $p->parse($chunk);
            }
            else {
                $p->eof;
                $done++;
            }
            join '', splice @out;
        }
    });
}

sub token_not_found {
    my ($self, $env) = (shift, shift);
    if(my $app_for_blocked = $self->blocked) {
        return $app_for_blocked->($env, @_);
    }
    else {
        my $body = 'CSRF detected';
        return [
            403,
            [ 'Content-Type' => 'text/plain', 'Content-Length' => length($body) ],
            [ $body ]
        ];
    }
}

1;
__END__

=head1 NAME

Plack::Middleware::CSRFBlock - CSRF are never propageted to app

=head1 SYNOPSIS

  use Plack::Builder;

  my $app = sub { ... }

  builder {
    enable 'Session';
    enable 'CSRFBlock';
    $app;
  }

=head1 DESCRIPTION

This middleware blocks CSRF. You can use this middleware without any modifications
to your application, in most cases. Here is the strategy:

=over 4

=item output filter

When the application response content-type is "text/html" or
"application/xhtml+xml", this inserts hidden input tag that contains token
string into C<form>s in the response body.  It can also adds an optional meta
tag (by setting C<add_meta> to true) with the default name "csrftoken".
For example, the application response body is:

  <html>
    <head>
        <title>input form</title>
    </head>
    <body>
      <form action="/receive" method="post">
        <input type="text" name="email" /><input type="submit" />
      </form>
  </html>

this becomes:

  <html>
    <head><meta name="csrftoken" content="0f15ba869f1c0d77"/>
        <title>input form</title>
    </head>
    <body>
      <form action="/api" method="post"><input type="hidden" name="SEC" value="0f15ba869f1c0d77" />
        <input type="text" name="email" /><input type="submit" />
      </form>
  </html>

This affects C<form> tags with C<method="post">, case insensitive.

=item input check

For every POST requests, this module checks input parameters contain the
collect token parameter. If not found, throws 403 Forbidden by default.

Supports C<application/x-www-form-urlencoded> and C<multipart/form-data>.

=back

=head1 OPTIONS

  use Plack::Builder;
  
  my $app = sub { ... }
  
  builder {
    enable 'Session';
    enable 'CSRFBlock',
      parameter_name => 'csrf_secret',
      token_length => 20,
      session_key => 'csrf_token',
      blocked => sub {
        [302, [Location => 'http://www.google.com'], ['']];
      },
      onetime => 0,
      ;
    $app;
  }

=over 4

=item parameter_name (default:"SEC")

Name of the input tag for the token.

=item add_meta (default: 0)

Whether or not to append a C<meta> tag to pages that
contains the token.  This is useful for getting the
value of the token from Javascript.  The name of the
meta tag can be set via C<meta_name> which defaults
to C<csrftoken>.

=item meta_name (default:"csrftoken")

Name of the C<meta> tag added to the C<head> tag of
output pages.  The content of this C<meta> tag will be
the token value.  The purpose of this tag is to give
javascript access to the token if needed for AJAX requests.

=item header_name (default:"X-CSRF-Token")

Name of the HTTP Header that the token can be sent in.
This is useful for sending the header for Javascript AJAX requests,
and this header is required for any post request that is not
of type C<application/x-www-form-urlencoded> or C<multipart/form-data>.

=item token_length (default:16);

Length of the token string. Max value is 40.

=item session_key (default:"csrfblock.token")

This middleware uses L<Plack::Middleware::Session> for token storage. this is
the session key for that.

=item blocked (default:403 response)

The application called when CSRF is detected.

Note: This application can read posted data, but DO NOT use them!

=item onetime (default:FALSE)

If this is true, this middleware uses B<onetime> token, that is, whenever
client sent collect token and this middleware detect that, token string is
regenerated.

This makes your applications more secure, but in many cases, is too strict.

=back

=head1 CAVEATS

This middleware doesn't work with pure Ajax POST request, because it cannot
insert the token parameter to the request. We suggest, for example, to use
jQuery Form Plugin like:

  <script type="text/javascript" src="jquery.js"></script>
  <script type="text/javascript" src="jquery.form.js"></script>

  <form action="/api" method="post" id="theform">
    ... blah ...
  </form>
  <script type="text/javascript>
    $('#theform').ajaxForm();
  </script>

so, the middleware can insert token C<input> tag next to C<form> start tag,
and the client can send it by Ajax form.

=head1 AUTHOR

Rintaro Ishizaki E<lt>rintaro@cpan.orgE<gt>

=head1 SEE ALSO

L<Plack::Middleware::Session>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
