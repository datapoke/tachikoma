#!/usr/bin/perl
# ----------------------------------------------------------------------
# Tachikoma::Nodes::Shell3
# ----------------------------------------------------------------------
#

package Tachikoma::Nodes::Shell3;
use strict;
use warnings;
use Tachikoma::Node;
use Tachikoma::Nodes::Shell;
use Tachikoma::Nodes::Shell2;
use Tachikoma::Message qw(
    TYPE FROM TO PAYLOAD
    TM_BYTESTREAM TM_STORABLE TM_COMMAND TM_PING TM_EOF
    TM_INFO TM_REQUEST TM_COMPLETION TM_NOREPLY
);
use Tachikoma::Command;
use Carp;
use Data::Dumper qw( Dumper );
use Storable     qw( nfreeze );
my $USE_JSON;

BEGIN {
    $USE_JSON = eval {
        my $module_name = 'JSON';
        my $module_path = 'JSON.pm';
        require $module_path;
        import $module_name;
        return 1;
    };
}
use parent qw( Tachikoma::Nodes::Shell );

use version; our $VERSION = qv('v2.0.280');

# special characters that need to be escaped: [(){}[]<>&|;"'`]

my %H = ();

my %PROMPTS = (
    string1 => q("> ),
    string2 => q('> ),
    string3 => q(`> ),
    newline => q(> ),
);
my %NEEDS_INPUT = (
    string1 => 1,
    string2 => 1,
    string3 => 1,
    newline => 1,
);
my %OPERATORS = (
    and        => 1,
    or         => 1,
    logical    => 1,
    op         => 1,
    arithmetic => 1,
);
my $SYMBOLIC_OPS = qr{[.][.]|!~|=~|!=?|<=?|>=?|==|&&|[|][|]};
my $NAMED_OPS    = qr{eq\b|ne\b|lt\b|gt\b|le\b|ge\b};
my %EXPRESSIONS  = (
    parenthesized_expr => 1,
    binary_expression  => 1,
    unary_expression   => 1,
);
my %SAFE_TYPES = (
    ident      => 1,
    number     => 1,
    string1    => 1,
    string2    => 1,
    string3    => 1,
    string4    => 1,
    whitespace => 1,
    variable   => 1,
);
my %UNSAFE_TYPES = (
    and        => 1,
    or         => 1,
    not        => 1,
    logical    => 1,
    op         => 1,
    arithmetic => 1,
);
my %END_OF_COMMAND = (
    command => 1,
    pipe    => 1,
    eos     => 1,
);
my %END_OF_ASSIGNMENT = (
    command => 1,
    eos     => 1,
);
my %BUILTINS = ();
my @LOCAL    = ( {} );
my %SHARED   = ();
## no critic (ProhibitTies)
tie %SHARED, 'Tachikoma::Nodes::Shell3';

my $MSG_COUNTER = 0;

sub new {
    my $class = shift;
    my $self  = $class->SUPER::new;
    $self->{callbacks}    = {};
    $self->{cwd}          = undef;
    $self->{dirty}        = undef;
    $self->{errors}       = 0;
    $self->{message_id}   = undef;
    $self->{parse_buffer} = q();
    $self->{show_parse}   = undef;
    $self->{token_index}  = undef;
    $self->{tokens}       = undef;
    bless $self, $class;
    return $self;
}

sub new_func {
    my $self     = shift;
    my $name     = shift;
    my $body     = shift;
    my $function = join q(), "func $name {",
        $body =~ m{^\s} ? "\n$body};\n" : " $body };\n";
    $self->{configuration}->{help}->{$name} = [$function];
    my $tokens = $self->tokenize($function);
    my $ast    = $self->build_ast($tokens);
    $self->execute_ast_node($ast);
    return;
}

sub fill {
    my $self    = shift;
    my $message = shift;
    if ( $message->[FROM] eq '_stdin' ) {
        $message->[FROM] = '_responder';
    }
    else {
        $self->stderr( 'ERROR: invalid shell input: ', $message->as_string );
        $Tachikoma::Nodes{_stdin}->close_filehandle
            if ( $Tachikoma::Nodes{_stdin} );
        exit 1;
    }
    if ( $self->mode eq 'command' ) {
        $self->process_command($message);
    }
    else {
        $self->process_bytestream($message);
    }
    return;
}

sub process_command {    ## no critic (ProhibitExcessComplexity)
    my $self    = shift;
    my $message = shift;

    if ( $message->type & TM_EOF ) {
        $self->stderr('ERROR: got EOF while waiting for tokens')
            if ( $self->parse_buffer );
        return $self->shutdown_all_nodes
            if ( $self->{errors} and not $self->{isa_tty} );
        $message->to( $self->path );
        return $self->sink->fill($message);
    }

    $self->{counter}++;
    my $input = join q(), $self->parse_buffer, $message->payload;
    $self->parse_buffer(q());

    local $SIG{INT} = sub { die "^C\n" }
        if ( $self->{isa_tty} );

    # Use the new parsing pipeline
    my $tokens = $self->tokenize($input);

    if ( $self->{show_parse} ) {
        $self->stderr( Dumper($tokens) );
    }

    # Check for unclosed quotes that need more input
    my $last_token = $tokens->[-2];    # -1 is always EOS
    if (   $last_token
        && $NEEDS_INPUT{ $last_token->{type} }
        && !$last_token->{value} )
    {
        $self->parse_buffer($input);
        my $prompt = $PROMPTS{ $last_token->{type} } || '> ';
        $Tachikoma::Nodes{_stdin}->prompt($prompt)
            if ( $self->{isa_tty} );
        return;
    }

    my $ast  = undef;
    my $okay = eval {

        # Continue with parsing if we have a complete statement
        $ast = $self->build_ast($tokens);
        return 1;
    };

    if ( $self->{show_parse} ) {
        $self->stderr( Dumper($ast) );
    }

    if ( not $okay ) {

        # Blocks, brackets, and parenthesized expressions may need more input
        if ( $@ eq "WANT_MORE_INPUT\n" ) {
            $self->parse_buffer($input);
            my $prompt = '> ';
            $Tachikoma::Nodes{_stdin}->prompt($prompt)
                if ( $self->{isa_tty} );
            return;
        }

        # Handle errors as before
        my $error = $@ || 'unknown error';
        $error =~ s{ at /\S+ line \d+[.]}{.};
        chomp $error;
        $self->stderr("$error\n");
        $self->{errors}++;
    }

    # Execute command(s) and write output
    $okay = eval {
        my $rv     = $self->execute_ast_node($ast);
        my $output = join q(), @{$rv};
        syswrite STDOUT, $output or die if ( length $output );
        return 1;
    };

    if ( not $okay ) {
        my $error = $@ || 'unknown error';
        $error =~ s{ at /\S+ line \d+[.]}{.};
        chomp $error;
        $self->stderr("$error\n");
        $self->{errors}++;
    }

    # Handle TTY prompts as before
    if ( $self->{isa_tty} ) {
        $self->get_completions if ( $self->dirty );
        $self->prompt          if ( $self->mode eq 'command' );
    }

    return;
}

sub process_bytestream {
    my $self    = shift;
    my $message = shift;
    if ( $message->type & TM_EOF ) {
        $message->from(q());
        $self->sink->fill($message);
        $self->path( $self->cwd );
        $self->cwd(undef);
        $self->mode('command');
        $self->prompt if ( $self->isa_tty );
    }
    elsif ( $message->payload eq ".\n" ) {
        $self->path( $self->cwd );
        $self->cwd(undef);
        $self->mode('command');
        $self->prompt if ( $self->isa_tty );
    }
    else {
        $message->to( $self->path );
        $message->stream( $self->FETCH('message.stream') );
        $self->sink->fill($message);
    }
    return;
}

sub tokenize {    ## no critic (ProhibitExcessComplexity)
    my $self     = shift;
    my $input    = shift;
    my @tokens   = ();
    my $in_quote = undef;
    my $a        = qr{[+-]}o;
    my $m        = qr{[*/]}o;
    my $x        = qr{[\w.,:*/\@\$\%^&?]+}o;

    while ( length $input ) {

        # Handle quoted strings
        if ($in_quote) {
            if ( $input =~ s/^((?:[^$in_quote\\]++|\\.)*+)$in_quote//s ) {
                $tokens[-1]->{value} = $1;
                $in_quote = undef;
            }
            else {
                # Unclosed quote
                $input = q();
            }
            next;
        }

        # Handle whitespace
        if ( $input =~ s/^(\s+)// ) {
            push @tokens, { type => 'whitespace', value => $1 };
            next;
        }

        # Handle comments
        if ( $input =~ s/^#.*// ) {
            next;
        }

        # Handle numbers
        if ( $input =~ s/^(-?\d+(?:[.]\d*)?|[.]\d+)// ) {
            push @tokens, { type => 'number', value => $1 };
            next;
        }

        # Handle variables
        if ( $input =~ s/^<([\w.:\@-]*)>// ) {
            push @tokens, { type => 'variable', value => $1 };
            next;
        }

        # Handle assignment operators
        if ( $input =~ s/^([.]=|[+][+]|--|[|][|]=|\/\/=|[+]=|-=|[*]=|\/=)// )
        {
            push @tokens, { type => 'op', value => $1 };
            next;
        }

        # Handle arithmetic operators
        if ( $input =~ s/^($a)// ) {
            push @tokens, { type => 'arithmetic', value => $1 };
            next;
        }
        if ( $input =~ /^$m(?!$x)/ ) {
            if (    $tokens[-1]
                and $tokens[-1]->{type} eq 'whitespace' )
            {
                if ( $input =~ s/^($m)// ) {
                    push @tokens, { type => 'arithmetic', value => $1 };
                }
                else {
                    die 'unexpected error';
                }
                next;
            }
        }

        # Handle logical operators
        if ( $input =~ s/^($SYMBOLIC_OPS|$NAMED_OPS)// ) {
            my $op = $1;
            my $type =
                  ( $op eq q(&&) ) ? 'and'
                : ( $op eq q(||) ) ? 'or'
                : ( $op eq q(!) )  ? 'not'
                :                    'logical';
            push @tokens, { type => $type, value => $op };
            next;
        }

        # Handle assignment operators
        if ( $input =~ s/^(=)// ) {
            push @tokens, { type => 'op', value => $1 };
            next;
        }

        # Handle command separators and pipes
        if ( $input =~ s/^([;|])// ) {
            my $sep  = $1;
            my $type = ( $sep eq q(|) ) ? 'pipe' : 'command';
            push @tokens, { type => $type, value => $sep };
            next;
        }

        # Handle parentheses, braces, brackets
        if ( $input =~ s/^([(){}\[\]])// ) {
            my $bracket = $1;
            my $type =
                  ( $bracket eq '(' ) ? 'open_paren'
                : ( $bracket eq ')' ) ? 'close_paren'
                : ( $bracket eq '{' ) ? 'open_brace'
                : ( $bracket eq '}' ) ? 'close_brace'
                : ( $bracket eq '[' ) ? 'open_bracket'
                :                       'close_bracket';
            push @tokens, { type => $type, value => $bracket };
            next;
        }

        # Handle quotes
        if ( $input =~ s/^(['"`])// ) {
            $in_quote = $1;
            push @tokens,
                {
                  type => $in_quote eq q(") ? 'string1'
                : $in_quote eq q(') ? 'string2'
                : 'string3',
                value => q()
                };
            next;
        }

        # Handle line continuation (backslash at end of line)
        if ( $input =~ s/^\\(?m:\n|$)// ) {
            push @tokens, { type => 'newline', value => q() };
            next;
        }

        # Handle identifiers
        if ( $input =~ s/^($x(?:$a$x)*)// ) {
            push @tokens, { type => 'ident', value => $1 };
            next;
        }

        # Handle escaped characters
        if ( $input =~ s/^\\(.)// ) {
            push @tokens, { type => 'string4', value => $1 };
            next;
        }

        # Handle unknown characters
        $input =~ s/^.//;
        $self->stderr("ERROR: Unrecognized character: $&");
    }

    # Add an explicit EOS token
    push @tokens, { type => 'eos', value => q() };

    return \@tokens;
}

sub build_ast {
    my $self   = shift;
    my $tokens = shift;
    $self->token_index(0);
    $self->tokens($tokens);
    return $self->parse_command_list;
}

sub current_token {
    my $self = shift;
    return $self->{tokens}[ $self->{token_index} ]
        if $self->{token_index} < @{ $self->{tokens} };
    return { type => 'eos', value => q() };
}

sub consume {
    my $self          = shift;
    my $expected_type = shift;
    my $token         = $self->current_token;
    if ( $expected_type && $token->{type} ne $expected_type ) {
        $self->fatal_parse_error(
            "Expected $expected_type, got $token->{type}");
    }
    $self->{token_index}++;
    return $token;
}

sub parse_command_list {
    my $self     = shift;
    my @commands = ();

    while ( $self->current_token->{type} ne 'eos' ) {

        # Parse command
        my $command = $self->parse_command;
        push @commands, $command if $command;

        # Check for command separator
        if ( $self->current_token->{type} eq 'command' ) {
            $self->consume('command');
        }
        elsif ( $self->current_token->{type} eq 'eos' ) {

            # If no separator and not at end, could be an error
            last;
        }
    }

    return { type => 'command_list', commands => \@commands };
}

sub parse_command {
    my $self = shift;
    $self->consume('whitespace')
        while ( $self->current_token->{type} eq 'whitespace' );
    my $token = $self->current_token;

    # Check for special structures
    if ( $token->{type} eq 'open_brace' ) {
        return $self->parse_block;
    }
    elsif ( $token->{type} eq 'open_bracket' ) {
        return $self->parse_bracket;
    }
    elsif ( $token->{type} eq 'open_paren' ) {
        return $self->parse_parenthesized_expr;
    }
    else {
        # Parse first command
        my $left_cmd = $self->parse_simple_command;

        # Check for pipe operator
        if ( $self->current_token->{type} eq 'pipe' ) {
            $self->consume('pipe');
            $self->consume('whitespace')
                while ( $self->current_token->{type} eq 'whitespace' );

            # Parse right side (could be another command or a pipe chain)
            my $right_cmd = $self->parse_command;

            return {
                type  => 'pipe',
                left  => $left_cmd,
                right => $right_cmd
            };
        }

        return $left_cmd;
    }
}

sub parse_simple_command {
    my $self       = shift;
    my $name_token = $self->consume;
    my @args       = ();
    if ( $name_token->{type} eq 'ident' ) {
        if ( $name_token->{value} eq 'env' ) {
            return $self->parse_env_assignment;
        }
        elsif ( $name_token->{value} eq 'var' ) {
            return $self->parse_var_assignment;
        }
        elsif ( $name_token->{value} eq 'local' ) {
            return $self->parse_local_assignment;
        }

        my $ate_whitespace = undef;
        while ( $self->current_token->{type} eq 'whitespace' ) {
            $self->consume('whitespace');
            $ate_whitespace = 1;
        }

        # If second token is an assignment operator, the name is a variable
        if ($self->current_token->{type} eq 'op'
            and
            ( not $ate_whitespace or $self->current_token->{value} ne q(--) )
            )
        {
            return $self->parse_assignment($name_token);
        }
    }

    # Parse arguments until end of command
    while ( not $END_OF_COMMAND{ $self->current_token->{type} } ) {
        my $arg = undef;

        if ( $SAFE_TYPES{ $self->current_token->{type} } ) {
            $arg = $self->consume;
        }
        elsif ( $UNSAFE_TYPES{ $self->current_token->{type} } ) {
            $arg = $self->consume;
            $arg->{type} = 'ident';
        }
        elsif ( $self->current_token->{type} eq 'open_brace' ) {
            $arg = $self->parse_block;
        }
        elsif ( $self->current_token->{type} eq 'open_bracket' ) {
            $arg = $self->parse_bracket;
        }
        elsif ( $self->current_token->{type} eq 'open_paren' ) {
            $arg = $self->parse_parenthesized_expr;
        }
        elsif ( $self->current_token->{type} eq 'newline' ) {
            $self->consume;
        }
        else {
            last;
        }

        push @args, $arg if $arg;
    }

    return {
        type => $name_token->{type} eq 'ident'
        ? 'command'
        : $name_token->{type},
        name => $name_token->{value},
        args => \@args
    };
}

sub parse_env_assignment {
    my $self   = shift;
    my $branch = $self->parse_local_assignment;
    $branch->{type} = 'env_assignment';
    return $branch;
}

sub parse_var_assignment {
    my $self   = shift;
    my $branch = $self->parse_local_assignment;
    $branch->{type} = 'var_assignment';
    return $branch;
}

sub parse_local_assignment {
    my $self = shift;
    $self->consume('whitespace')
        while ( $self->current_token->{type} eq 'whitespace' );
    my $name_token = undef;
    my $op         = undef;
    my $expr       = undef;
    if ( $self->current_token->{type} =~ /^(ident|string\d|variable)$/ ) {
        $name_token = $self->consume;
        $self->consume('whitespace')
            while ( $self->current_token->{type} eq 'whitespace' );
        if ( $self->current_token->{type} eq 'op' ) {
            $op = $self->consume('op');
            $self->consume('whitespace')
                while ( $self->current_token->{type} eq 'whitespace' );
            $expr =
                (       $op->{value} ne q(++)
                    and $op->{value} ne q(--)
                    and
                    not $END_OF_ASSIGNMENT{ $self->current_token->{type} } )
                ? $self->parse_expression_list
                : undef;
        }
    }
    if ( $self->current_token->{type} !~ /^command|eos|close_\w+$/ ) {
        $self->fatal_parse_error( 'Unexpected token in assignment: '
                . $self->current_token->{type} );
    }
    return {
        type     => 'local_assignment',
        name     => $name_token,
        operator => $op ? $op->{value} : undef,
        value    => $expr
    };
}

sub parse_assignment {
    my $self       = shift;
    my $name_token = shift;
    my $op         = $self->consume('op');
    $self->consume('whitespace')
        while ( $self->current_token->{type} eq 'whitespace' );
    my $expr =
        (       $op->{value} ne q(++)
            and $op->{value} ne q(--)
            and not $END_OF_ASSIGNMENT{ $self->current_token->{type} } )
        ? $self->parse_expression_list
        : undef;
    return {
        type     => 'assignment',
        name     => $name_token->{value},
        operator => $op->{value},
        value    => $expr
    };
}

sub parse_block {
    my $self = shift;

    # Consume the opening brace
    $self->consume('open_brace');

    # Parse the block content
    my @commands = ();
    while ( $self->current_token->{type} ne 'close_brace' ) {
        my $command = $self->parse_command;
        push @commands, $command if $command;

        # Check for command separator
        if ( $self->current_token->{type} eq 'command' ) {
            $self->consume('command');
            $self->consume('whitespace')
                while ( $self->current_token->{type} eq 'whitespace' );
        }
        elsif ( $self->current_token->{type} eq 'eos' ) {

            # End of input, throw exception
            die "WANT_MORE_INPUT\n";
        }
    }

    # Consume the closing brace
    $self->consume('close_brace');

    $self->consume('whitespace')
        while ( $self->current_token->{type} eq 'whitespace' );

    return {
        type     => 'block',
        commands => \@commands
    };
}

sub parse_bracket {
    my $self = shift;

    # Consume the opening bracket
    $self->consume('open_bracket');

    # Parse the block content
    my @commands = ();
    while ( $self->current_token->{type} ne 'close_bracket' ) {
        my $command = $self->parse_command;
        push @commands, $command if $command;

        # Check for command separator
        if ( $self->current_token->{type} eq 'command' ) {
            $self->consume('command');
            $self->consume('whitespace')
                while ( $self->current_token->{type} eq 'whitespace' );
        }
        elsif ( $self->current_token->{type} eq 'eos' ) {

            # End of input, throw exception
            die "WANT_MORE_INPUT\n";
        }
    }

    # Consume the closing bracket
    $self->consume('close_bracket');

    return {
        type     => 'bracket',
        commands => \@commands
    };
}

# Define operator precedence
my %PRECEDENCE = (
    q(=~) => 9,
    q(!~) => 9,
    q(*)  => 8,
    q(/)  => 8,
    q(%)  => 8,
    q(+)  => 7,
    q(-)  => 7,
    q(<)  => 6,
    q(>)  => 6,
    q(<=) => 6,
    q(>=) => 6,
    q(lt) => 6,
    q(gt) => 6,
    q(le) => 6,
    q(ge) => 6,
    q(==) => 5,
    q(!=) => 5,
    q(eq) => 5,
    q(ne) => 5,
    q(..) => 4,
    q(!)  => 3,
    q(&&) => 2,
    q(||) => 1,
);

sub parse_expression {
    my $self           = shift;
    my $min_precedence = shift || 0;

    $self->consume('whitespace')
        while ( $self->current_token->{type} eq 'whitespace' );

    my $left       = $self->parse_primary_expression;
    my $whitespace = undef;

    $whitespace = $self->consume('whitespace')
        while ( $self->current_token->{type} eq 'whitespace' );

    while ($OPERATORS{ $self->current_token->{type} }
        && exists $PRECEDENCE{ $self->current_token->{value} }
        && $PRECEDENCE{ $self->current_token->{value} } >= $min_precedence )
    {
        my $op         = $self->consume->{value};
        my $precedence = $PRECEDENCE{$op};

        # For right-associative operators, use precedence - 1
        # For left-associative operators like +, -, *, /, use precedence + 1
        # to ensure proper left-to-right evaluation
        my $next_min_precedence = $precedence + 1;

        my $right = $self->parse_expression($next_min_precedence);

        $left = {
            type     => 'binary_expression',
            operator => $op,
            left     => $left,
            right    => $right
        };
    }

    return ( ( wantarray and $whitespace ) ? ( $left, $whitespace ) : $left );
}

sub parse_primary_expression {
    my $self  = shift;
    my $token = $self->current_token;

    # Handle not operator
    if ( $token->{type} eq 'not' ) {
        my $op   = $self->consume('not');
        my $expr = $self->parse_expression( $PRECEDENCE{ $op->{value} } );
        return {
            type       => 'unary_expression',
            operator   => $op->{value},
            expression => $expr
        };
    }

    # Handle negative operator
    if ( $token->{type} eq 'arithmetic' and $token->{value} eq q(-) ) {
        my $op   = $self->consume('arithmetic');
        my $expr = $self->parse_expression;
        return {
            type       => 'unary_expression',
            operator   => $op->{value},
            expression => $expr
        };
    }

    # Handle braces, brackets, and parentheses
    if ( $token->{type} eq 'open_brace' ) {
        return $self->parse_block;
    }
    elsif ( $token->{type} eq 'open_bracket' ) {
        return $self->parse_bracket;
    }
    elsif ( $token->{type} eq 'open_paren' ) {
        return $self->parse_parenthesized_expr;
    }

    # Handle literals
    if ( $token->{type} =~ /^(ident|number|op|string\d)$/ ) {
        return {
            type  => $1,
            value => $self->consume->{value}
        };
    }

    # Handle variables
    if ( $token->{type} eq 'variable' ) {
        return {
            type  => 'variable',
            value => $self->consume('variable')->{value}
        };
    }

    # Handle unexpected close_paren
    if ( $token->{type} eq 'close_paren' ) {
        return {
            type  => 'ident',
            value => q()
        };
    }

    # Handle end of input, throw exception
    if ( $token->{type} eq 'eos' ) {
        die "WANT_MORE_INPUT\n";
    }

    return $self->fatal_parse_error(
        'Unexpected token in expression: ' . $token->{type} );
}

sub parse_parenthesized_expr {
    my $self = shift;

    # Consume the opening parenthesis
    $self->consume('open_paren');

    # Parse the expression
    my $expr = [];
    while ( $self->current_token->{type} ne 'close_paren' ) {
        push @{$expr}, $self->parse_expression;

        # Handle end of input, throw exception
        if ( $self->current_token->{type} eq 'eos' ) {
            die "WANT_MORE_INPUT\n";
        }
    }
    pop @{$expr} while ( @{$expr} and $expr->[-1]->{type} eq 'whitespace' );

    # Consume the closing parenthesis
    $self->consume('close_paren');

    return {
        type        => 'parenthesized_expr',
        expressions => $expr
    };
}

sub parse_expression_list {
    my $self = shift;

    # Parse the expression
    my $expr = [];
    while ( $self->current_token->{type} !~ /^command|eos|close_\w+$/ ) {
        push @{$expr}, $self->parse_expression;
    }

    return {
        type        => 'parenthesized_expr',
        expressions => $expr
    };
}

sub execute_ast_node {    ## no critic (ProhibitExcessComplexity)
    my $self = shift;
    my $node = shift;
    if ( not $node or ref $node ne 'HASH' ) {
        confess 'ERROR: Invalid AST node: ', Dumper($node);
    }

    if ( $node->{type} eq 'command_list' ) {
        my $result = [];
        for my $cmd ( @{ $node->{commands} } ) {
            my $cmd_result = $self->execute_ast_node($cmd);
            push @{$result}, @{$cmd_result} if $cmd_result;
        }
        return $result;
    }

    if ( $node->{type} =~ /^(command|string\d|variable)$/ ) {
        my $name = $node->{name};
        $name = $SHARED{$name} if ( $node->{type} eq 'variable' );

        return if ( $self->{validate} );

        my $rv = undef;
        if ( $BUILTINS{$name} ) {

            # Handle builtin commands
            $rv = $BUILTINS{$name}->( $self, $node );
        }
        else {
            # Handle other commands
            $rv = $self->send_command($node);
        }
        if ($rv) {
            return $rv;
        }
        else {
            $self->stderr("ERROR: Unknown command: $name\n");
            return;
        }
    }

    # Handle variable assignments
    if ( $node->{type} eq 'env_assignment' ) {
        return $self->execute_env_assignment($node);
    }
    if ( $node->{type} eq 'var_assignment' ) {
        return $self->execute_var_assignment($node);
    }
    if ( $node->{type} eq 'local_assignment' ) {
        return $self->execute_local_assignment($node);
    }
    if ( $node->{type} eq 'assignment' ) {
        return $self->execute_assignment($node);
    }

    # Handle other node types
    if ( $node->{type} eq 'block' ) {
        my $result = [];

        # localize variables
        unshift @LOCAL, {};
        for my $cmd ( @{ $node->{commands} } ) {
            my $cmd_result = $self->execute_ast_node($cmd);
            push @{$result}, @{$cmd_result} if $cmd_result;
        }
        shift @LOCAL;
        return $result;
    }

    if ( $node->{type} eq 'bracket' ) {
        my $result = [];
        for my $cmd ( @{ $node->{commands} } ) {
            my $cmd_result = $self->execute_ast_node($cmd);
            push @{$result}, @{$cmd_result} if $cmd_result;
        }
        return $result;
    }

    if ( $node->{type} eq 'parenthesized_expr' ) {
        my $result = [];
        for my $sub_expr ( @{ $node->{expressions} } ) {
            push @{$result}, @{ $self->execute_expression($sub_expr) };
        }
        return $result;
    }

    # Handle pipe operations
    if ( $node->{type} eq 'pipe' ) {
        my $left_cmd  = $node->{left};
        my $right_cmd = $node->{right};

        # Get the right-side command chain
        my @functions = ();

        # If right side is another pipe, collect all commands in the chain
        if ( $right_cmd->{type} eq 'pipe' ) {
            my $pipe_node = $right_cmd;
            push @functions, $pipe_node->{left};

            # Follow the pipe chain to collect all commands
            while ( $pipe_node->{right}->{type} eq 'pipe' ) {
                $pipe_node = $pipe_node->{right};
                push @functions, $pipe_node->{left};
            }
            push @functions, $pipe_node->{right};
        }
        else {
            # Just a simple pipe with two commands
            push @functions, $right_cmd;
        }

        # Set up the pipeline
        return [] if ( $self->{validate} );

        my $id = $self->msg_counter;
        $self->message_id($id);

        # Register callback(s) for the piped command(s)
        if ( @functions > 1 ) {
            $self->callbacks->{$id} = {
                type  => 'pipe',
                value => \@functions
            };
        }
        else {
            $self->callbacks->{$id} = $functions[0];
        }

        # Execute the left command with the callback registered
        unshift @LOCAL, { 'message.from' => '_responder' };
        my $result = $self->execute_ast_node($left_cmd);
        shift @LOCAL;
        $self->message_id(undef);

        return $result;
    }

    return [];
}

sub execute_expression {    ## no critic (ProhibitExcessComplexity)
    my $self = shift;
    my $expr = shift || return [];

    # Handle different expression types
    if ( $expr->{type} eq 'binary_expression' ) {
        my $left_val  = $self->execute_expression( $expr->{left} );
        my $right_val = $self->execute_expression( $expr->{right} );

        # Get scalar values - ensure we properly extract values from arrays
        my $left_scalar =
            ref $left_val eq 'ARRAY'
            ? join q(), @{$left_val}
            : $left_val // q();
        my $right_scalar =
            ref $right_val eq 'ARRAY'
            ? join q(), @{$right_val}
            : $right_val // q();

        # Evaluate based on the operator
        my $op = $expr->{operator};
        my $result;

        if ( $op eq q(||) ) {
            $result = [ $left_scalar || $right_scalar ];
        }
        elsif ( $op eq q(&&) ) {
            $result = [ $left_scalar && $right_scalar ];
        }
        elsif ( $op eq q(+) ) {
            $result = [ $left_scalar + $right_scalar ];
        }
        elsif ( $op eq q(-) ) {
            $result = [ $left_scalar - $right_scalar ];
        }
        elsif ( $op eq q(*) ) {
            $result = [ $left_scalar * $right_scalar ];
        }
        elsif ( $op eq q(/) ) {
            $result = [ $left_scalar / $right_scalar ];
        }
        elsif ( $op eq q(==) ) {
            $result = [ $left_scalar == $right_scalar ];
        }
        elsif ( $op eq q(!=) ) {
            $result = [ $left_scalar != $right_scalar ];
        }
        elsif ( $op eq q(<) ) {
            $result = [ $left_scalar < $right_scalar ];
        }
        elsif ( $op eq q(>) ) {
            $result = [ $left_scalar > $right_scalar ];
        }
        elsif ( $op eq q(<=) ) {
            $result = [ $left_scalar <= $right_scalar ];
        }
        elsif ( $op eq q(>=) ) {
            $result = [ $left_scalar >= $right_scalar ];
        }
        elsif ( $op eq q(..) ) {
            $result = [ map { $_ => q( ) } $left_scalar .. $right_scalar ];
            pop @{$result};
        }
        elsif ( $op eq q(=~) ) {
            $result = [ $left_scalar =~ /$right_scalar/ ];
            for my $i ( 0 .. $#{$result} ) {
                $LOCAL[0]->{ q(_) . ( $i + 1 ) } = [ $result->[$i] ];
            }
        }
        elsif ( $op eq q(!~) ) {
            $result = [ $left_scalar !~ $right_scalar ];
        }
        elsif ( $op eq 'lt' ) {
            $result = [ $left_scalar lt $right_scalar ];
        }
        elsif ( $op eq 'gt' ) {
            $result = [ $left_scalar gt $right_scalar ];
        }
        elsif ( $op eq 'le' ) {
            $result = [ $left_scalar le $right_scalar ];
        }
        elsif ( $op eq 'ge' ) {
            $result = [ $left_scalar ge $right_scalar ];
        }
        elsif ( $op eq 'ne' ) {
            $result = [ $left_scalar ne $right_scalar ];
        }
        elsif ( $op eq 'eq' ) {
            $result = [ $left_scalar eq $right_scalar ];
        }
        else {
            $self->fatal_parse_error("Unknown operator: $op");
        }
        return $result;
    }
    if ( $expr->{type} eq 'unary_expression' ) {
        my $value = $self->execute_expression( $expr->{expression} );
        my $op    = $expr->{operator};

        # Get scalar value
        my $scalar_value =
            ref $value eq 'ARRAY'
            ? join q(), @{$value}
            : $value;

        # Evaluate based on the operator
        if ( $op eq q(!) ) {
            return [ !$scalar_value ];
        }
        elsif ( $op eq q(-) ) {
            return [ -$scalar_value ];
        }
        else {
            $self->fatal_parse_error("Unknown unary operator: $op");
        }
    }
    if ( $expr->{type} eq 'parenthesized_expr' ) {
        my $result = [];
        for my $sub_expr ( @{ $expr->{expressions} } ) {
            push @{$result}, @{ $self->execute_expression($sub_expr) };
        }
        return $result;
    }
    if ( $expr->{type} eq 'block' or $expr->{type} eq 'bracket' ) {
        return $self->execute_ast_node($expr);
    }
    if ( $expr->{type} =~ /^(ident|number|op|string\d|whitespace)$/ ) {
        my $value = $expr->{value};
        if ( $expr->{type} eq 'string1' ) {
            $value =~ s{(?<!\\)<([^<>]+)>}{$SHARED{$1}}g;
            $value =~ s/\\([<>])/$1/g;
            $value =~ s/\\e/\e/g;
            $value =~ s/\\n/\n/g;
            $value =~ s/\\r/\r/g;
            $value =~ s/\\t/\t/g;
            $value =~ s/\\(")/"/g;
            $value =~ s/\\\\/\\/g;
        }
        elsif ( $expr->{type} eq 'string2' ) {
            $value =~ s/\\(')/'/g;
            $value =~ s/\\\\/\\/g;
        }
        elsif ( $expr->{type} eq 'string3' ) {
            $value =~ s{(?<!\\)<([^<>]+)>}{$SHARED{$1}}g;
            $value =~ s/\\([<>])/$1/g;
            $value =~ s/\\e/\e/g;
            $value =~ s/\\n/\n/g;
            $value =~ s/\\r/\r/g;
            $value =~ s/\\t/\t/g;
            $value =~ s/\\(`)/`/g;
            $value =~ s/\\\\/\\/g;
            $value = `$value`;    ## no critic (ProhibitBacktickOperators)
            return [ split /(\s+)/, $value ];
        }
        elsif ( $expr->{type} eq 'string4' ) {
            $value =~ s{(?<!\\)<([^<>]+)>}{$SHARED{$1}}g;
            $value =~ s/\\([(){}\[\]<>&|;"'`])/$1/g;
            $value =~ s/\\\\/\\/g;
        }
        return [$value];
    }
    if ( $expr->{type} eq 'variable' ) {
        my $value = $self->get_shared( $expr->{value} ) // q();
        return ref $value ? $value : [$value];
    }
    return $self->fatal_parse_error("Unknown expression type: $expr->{type}");
}

sub expand_expression {    ## no critic (ProhibitExcessComplexity)
    my $self = shift;
    my $expr = shift || return [];

    # Handle different expression types
    if ( $expr->{type} eq 'binary_expression' ) {
        my $left_val  = $self->expand_expression( $expr->{left} );
        my $right_val = $self->expand_expression( $expr->{right} );

        # Get scalar values - ensure we properly extract values from arrays
        my $left_scalar =
            ref $left_val eq 'ARRAY'
            ? join q(), @{$left_val}
            : $left_val;
        my $right_scalar =
            ref $right_val eq 'ARRAY'
            ? join q(), @{$right_val}
            : $right_val;

        # Evaluate based on the operator
        my $op     = $expr->{operator};
        my $result = [ $left_scalar, $op, $right_scalar ];
        return $result;
    }
    if ( $expr->{type} eq 'unary_expression' ) {
        my $value = $self->expand_expression( $expr->{expression} );
        my $op    = $expr->{operator};

        # Get scalar value
        my $scalar_value =
            ref $value eq 'ARRAY'
            ? join q(), @{$value}
            : $value;

        # Evaluate based on the operator
        if ( $op eq q(!) ) {
            return [ q(!), $scalar_value ];
        }
        elsif ( $op eq q(-) ) {
            return [ q(-), $scalar_value ];
        }
        else {
            $self->fatal_parse_error("Unknown unary operator: $op");
        }
    }
    if ( $expr->{type} eq 'parenthesized_expr' ) {
        my $result = [];
        for my $sub_expr ( @{ $expr->{expressions} } ) {
            push @{$result}, @{ $self->execute_expression($sub_expr) };
        }
        return $result;
    }
    if ( $expr->{type} eq 'block' or $expr->{type} eq 'bracket' ) {
        return $self->execute_ast_node($expr);
    }
    if ( $expr->{type} =~ /^(ident|number|op|string\d|whitespace)$/ ) {
        my $value = $expr->{value};
        if ( $expr->{type} eq 'string1' ) {
            $value =~ s{(?<!\\)<([^<>]+)>}{$SHARED{$1}}g;
            $value =~ s/\\([<>])/$1/g;
            $value =~ s/\\e/\e/g;
            $value =~ s/\\n/\n/g;
            $value =~ s/\\r/\r/g;
            $value =~ s/\\t/\t/g;
            $value =~ s/\\(")/"/g;
            $value =~ s/\\\\/\\/g;
        }
        elsif ( $expr->{type} eq 'string2' ) {
            $value =~ s/\\(')/'/g;
            $value =~ s/\\\\/\\/g;
        }
        elsif ( $expr->{type} eq 'string3' ) {
            $value =~ s{(?<!\\)<([^<>]+)>}{$SHARED{$1}}g;
            $value =~ s/\\([<>])/$1/g;
            $value =~ s/\\e/\e/g;
            $value =~ s/\\n/\n/g;
            $value =~ s/\\r/\r/g;
            $value =~ s/\\t/\t/g;
            $value =~ s/\\(`)/`/g;
            $value =~ s/\\\\/\\/g;
            $value = `$value`;    ## no critic (ProhibitBacktickOperators)
            return [ split /(\s+)/, $value ];
        }
        elsif ( $expr->{type} eq 'string4' ) {
            $value =~ s{(?<!\\)<([^<>]+)>}{$SHARED{$1}}g;
            $value =~ s/\\([(){}\[\]<>&|;"'`])/$1/g;
            $value =~ s/\\\\/\\/g;
        }
        return [$value];
    }
    if ( $expr->{type} eq 'variable' ) {
        my $value = $self->get_shared( $expr->{value} ) // q();
        return ref $value ? $value : [$value];
    }
    return $self->fatal_parse_error("Unknown expression type: $expr->{type}");
}

sub fatal_parse_error {
    my $self  = shift;
    my $error = shift;
    die "ERROR: $error, line $self->{counter}\n";
}

###########
# Builtins
###########

$H{'read'} = [ "read [ <var name> ]\n", "local foo = {read}\n" ];

$BUILTINS{'read'} = sub {
    my $self = shift;
    my $node = shift;

    # Get arguments from the AST node
    my $args = $self->get_args($node);
    $self->fatal_parse_error('bad arguments for read')
        if ( @{$args} > 1 );

    # Get variable name if provided
    my $name = q();
    if ( @{$args} ) {
        $name = join q(), @{ $self->expand_expression( $args->[0] ) };
    }

    # Read from standard input
    $Tachikoma::Nodes{_stdin}->pause if ( $self->{isa_tty} );
    my $line = eval {<STDIN>};
    $Tachikoma::Nodes{_stdin}->resume if ( $self->{isa_tty} );
    die $@                            if ( not defined $line );

    # Store in variable or return directly
    if ($name) {
        chomp $line;
        $LOCAL[0]->{$name} = [$line];
        return [];
    }
    else {
        return [$line];
    }
};

$H{'print'} = [qq(print "<message>\\n"\n)];

$BUILTINS{'print'} = sub {
    my $self = shift;
    my $node = shift;

    # Get arguments from the AST node
    my $args = $self->get_args($node);
    $self->fatal_parse_error('bad arguments for print')
        if ( @{$args} != 1 );

    # Get message to print
    my $output = join q(), @{ $self->expand_expression( $args->[0] ) };

    # Write to standard output
    syswrite STDOUT, $output or die if ( length $output );
    return [];
};

$H{'split'} = [qq(split ':' <string>\n)];

$BUILTINS{'split'} = sub {
    my $self = shift;
    my $node = shift;

    # Get arguments from the AST node
    my $args = $self->get_args($node);
    $self->fatal_parse_error('bad arguments for split')
        if ( @{$args} != 2 );

    # Split the string into words
    my $separator = join q(), @{ $self->expand_expression( shift @{$args} ) };
    my @output    = ();
    for my $arg ( @{$args} ) {
        push @output, split $separator, join q(),
            @{ $self->expand_expression($arg) };
    }

    # Return array
    return \@output;
};

$H{'join'} = [qq(join ':' <args>\n)];

$BUILTINS{'join'} = sub {
    my $self = shift;
    my $node = shift;

    # Get arguments from the AST node
    my $args = $self->get_args($node);
    $self->fatal_parse_error('bad arguments for join')
        if ( @{$args} < 2 );

    # Join the arguments into a single string
    my $separator = join q(), @{ $self->expand_expression( shift @{$args} ) };
    my @list      = ();
    for my $arg ( @{$args} ) {
        push @list, @{ $self->expand_expression($arg) };
    }
    my $output = join $separator, @list;

    # Return string
    return [$output];
};

$H{'catn'} = [qq(<command> | catn\n)];

$BUILTINS{'catn'} = sub {
    my $self = shift;
    my $node = shift;

    # Get arguments from the AST node
    my $args = $self->get_args($node);
    $self->fatal_parse_error('bad arguments for catn')
        if ( @{$args} > 3 );

    # Get text to process (from args or previous command output)
    my $lines = q();
    if ( @{$args} ) {
        $lines = join q(), @{ $self->expand_expression( $args->[0] ) };
    }
    else {
        $lines = $LOCAL[0]->{q(@)} || q();
    }

    $self->fatal_parse_error('bad arguments for catn')
        if ( not defined $lines );

    # Format output with line numbers
    my $output = q();
    my $i      = 1;

    for my $line ( split m{^}, $lines ) {
        $output .= sprintf '%5d %s', $i++, $line;
    }

    # Return string
    return [$output];
};

$H{'grep'} = [qq(<command> | grep <regex>\n)];

$BUILTINS{'grep'} = sub {
    my $self = shift;
    my $node = shift;

    # Get arguments from the AST node
    my $args = $self->get_args($node);
    $self->fatal_parse_error('bad arguments for grep')
        if ( @{$args} > 2 );

    # Evaluate arguments
    my $regex = undef;
    my $lines = undef;

    if ( @{$args} >= 1 ) {
        my $result = $self->expand_expression( $args->[0] );
        $regex = join q(), @{$result};
    }

    if ( @{$args} >= 2 ) {
        my $result = $self->expand_expression( $args->[1] );
        $lines = join q(), @{$result};
    }
    else {
        # Fall back to previous command's output if no lines provided
        $lines = $LOCAL[0]->{q(@)} || q();
    }

    $self->fatal_parse_error('bad arguments for grep')
        if ( not defined $regex or not defined $lines );

    # Filter lines that don't match the regex
    my $output = q();
    for my $line ( split m{^}, $lines ) {
        $output .= $line if ( $line =~ m{$regex} );
    }

    # Return string
    return [$output];
};

$H{'grepv'} = [qq(<command> | grepv <regex>\n)];

$BUILTINS{'grepv'} = sub {
    my $self = shift;
    my $node = shift;

    # Get arguments from the AST node
    my $args = $self->get_args($node);
    $self->fatal_parse_error('bad arguments for grepv')
        if ( @{$args} > 2 );

    # Evaluate arguments
    my $regex = undef;
    my $lines = undef;

    if ( @{$args} >= 1 ) {
        my $result = $self->expand_expression( $args->[0] );
        $regex = join q(), @{$result};
    }
    if ( @{$args} >= 2 ) {
        my $result = $self->expand_expression( $args->[1] );
        $lines = join q(), @{$result};
    }
    else {
        # Fall back to previous command's output if no lines provided
        $lines = $LOCAL[0]->{q(@)} || q();
    }

    $self->fatal_parse_error('bad arguments for grepv')
        if ( not defined $regex or not defined $lines );

    # Filter lines that don't match the regex
    my $output = q();
    for my $line ( split m{^}, $lines ) {
        $output .= $line if ( $line !~ m{$regex} );
    }

    # Return string
    return [$output];
};

$H{'rand'} = [qq(rand [ <int> ]\n)];

$BUILTINS{'rand'} = sub {
    my $self = shift;
    my $node = shift;

    # Get arguments from the AST node
    my $args = $self->get_args($node);
    $self->fatal_parse_error('bad arguments for rand')
        if ( @{$args} > 1 );

    # Get the integer argument or use default
    my $int = 2;    # Default value
    if ( @{$args} ) {
        $int = join q(), @{ $self->expand_expression( $args->[0] ) };
        $self->fatal_parse_error('bad arguments for rand')
            if ( $int =~ m{\D} );    # Must be a number
    }

    # Generate and return random number
    return [ int rand $int ];
};

$H{'randarg'} = [qq(randarg <list>\n)];

$BUILTINS{'randarg'} = sub {
    my $self = shift;
    my $node = shift;

    # Get arguments from the AST node
    my $args = $self->get_args($node);
    $self->fatal_parse_error('bad arguments for randarg')
        if ( @{$args} < 1 );

    # Execute all arguments to get values
    my @arg_values =
        grep {/\S/} map { @{ $self->expand_expression($_) } } @{$args};

    # Make sure we have some values to choose from
    $self->fatal_parse_error('no valid arguments for randarg')
        if ( not @arg_values );

    # Select random argument
    my $count = scalar @arg_values;
    my $index = int rand $count;

    return [ $arg_values[$index] ];
};

$H{'local'} = [
    "local <name> [ <op> [ <value> ] ]\n",
    "    operators: = .= += -= *= /= //= ||=\n"
];

$H{'var'} = [
    "var <name> [ <op> [ <value> ] ]\n",
    "    operators: = .= += -= *= /= //= ||=\n"
];

$H{'env'} = [
    "env <name> [ <op> [ <value> ] ]\n",
    "    operators: = .= += -= *= /= //= ||=\n"
];

$H{'shift'} = ["local foo = { shift [ <var name> ] }\n"];

$BUILTINS{'shift'} = sub {
    my $self = shift;
    my $node = shift;

    # Get arguments from the AST node
    my $args = $self->get_args($node);

    # Process arguments
    my @arg_values = map { @{ $self->expand_expression($_) } } @{$args};
    my $key        = shift(@arg_values) // q(@);

    $self->fatal_parse_error('bad arguments for shift')
        if (@arg_values);

    # Get the hash containing the variable
    my $hash = $self->get_local_hash($key);

    # Handle variable lookup
    if ( not defined $hash ) {
        if ( defined $self->{configuration}->{var}->{$key} ) {
            $hash = $self->{configuration}->{var};
        }
        else {
            $self->stderr(
                "WARNING: use of uninitialized value <$key>, line $self->{counter}\n"
            );
            return [];
        }
    }

    # Get the value to shift from
    my $value = $hash->{$key};
    my $rv    = undef;

    # Handle different value types
    if ( ref $value ) {

        # For array values, shift the first element
        $rv = [ shift @{$value} // q() ];

        # Remove leading whitespace element if present
        shift @{$value} if ( @{$value} and $value->[0] =~ m{^\s*$} );

        # Clean up empty arrays
        $hash->{$key} = q() if ( not @{$value} );
    }
    else {
        # For scalar values, take the whole thing
        $rv = [$value];
        $hash->{$key} = q();
    }

    return $rv;
};

$H{'while'} = ["while (<expression>) { <commands> }\n"];

$BUILTINS{'while'} = sub {
    my $self = shift;
    my $node = shift;

    # Get arguments from the AST node
    my $args = $self->get_args($node);
    $self->fatal_parse_error('missing argument for while')
        if ( @{$args} < 2 );
    $self->fatal_parse_error('bad arguments for while')
        if ( @{$args} > 2 );

    # Extract test expression and body block
    my $test_expr  = $args->[0];
    my $body_block = $args->[1];

    # Execute the loop
    my $rv = [];
    while (1) {

        # Evaluate the test expression
        my $test_result = $self->execute_expression($test_expr);
        my $test_value  = join q(), @{$test_result};
        $test_value =~ s{^\s*|\s*$}{}g;    # Trim whitespace

        # Exit the loop if the condition is false
        last if ( not $test_value );

        # Execute the loop body
        $rv = $self->execute_ast_node($body_block);
    }

    return $rv;
};

$H{'if'} = [
    "if (<expression>) { <commands> }\n"
        . "[ elsif (<expression>) { <commands> } ]\n",
    "[ else { <commands> } ];\n"
];

$BUILTINS{'if'} = sub {
    my $self = shift;
    my $node = shift;

    # Get arguments from the AST node
    my $args = $self->get_args($node);
    $self->fatal_parse_error('missing argument for if')
        if ( @{$args} < 2 );

    my $test_expr  = $args->[0];
    my $then_block = $args->[1];
    my $rv         = [];

    # Check for elsif and else blocks
    my @elsif_tests  = ();
    my @elsif_blocks = ();

    # If we have additional arguments, they should be elsif/else blocks
    if ( @{$args} > 2 ) {
        my $i = 2;
        while ( $i < @{$args} ) {
            my $keyword = $args->[$i];

            # If it's a string literal containing the keyword
            if ( $keyword->{type} eq 'ident' ) {
                my $sugar = $keyword->{value};
                $i++;

                if ( $sugar eq 'elsif' ) {

                    # Expect test expression and block
                    my $elsif_test = $args->[ $i++ ]
                        || $self->fatal_parse_error(
                        'missing test expression for elsif');
                    my $elsif_block = $args->[ $i++ ]
                        || $self->fatal_parse_error(
                        'missing block for elsif');

                    push @elsif_tests,  $elsif_test;
                    push @elsif_blocks, $elsif_block;
                }
                elsif ( $sugar eq 'else' ) {

                    # Expect only a block
                    my $else_block = $args->[ $i++ ]
                        || $self->fatal_parse_error('missing block for else');

                    # Add else as an elsif with a condition that's always true
                    push @elsif_tests,
                        {
                        type  => 'number',
                        value => '1'
                        };
                    push @elsif_blocks, $else_block;
                }
                else {
                    $self->fatal_parse_error(
                        qq(bad arguments: "$sugar" expected: "else" or "elsif")
                    );
                }
            }
            else {
                $self->fatal_parse_error(
                    'expected keyword "elsif" or "else"');
            }
        }
    }

    # Evaluate the main if condition
    my $test_result = $self->execute_expression($test_expr);
    my $test_value  = join q(), @{$test_result};
    $test_value =~ s{^\s*|\s*$}{}g;    # Trim whitespace

    if ($test_value) {

        # If condition is true, execute the "then" block
        $rv = $self->execute_ast_node($then_block);
    }
    elsif (@elsif_tests) {

        # Check all elsif blocks in order
        for ( my $i = 0; $i < @elsif_tests; $i++ )
        {    ## no critic (ProhibitCStyleForLoops)
            my $elsif_result = $self->execute_expression( $elsif_tests[$i] );
            my $elsif_value  = join q(), @{$elsif_result};
            $elsif_value =~ s{^\s*|\s*$}{}g;    # Trim whitespace

            if ($elsif_value) {
                $rv = $self->execute_ast_node( $elsif_blocks[$i] );
                last;
            }
        }
    }

    return $rv;
};

$BUILTINS{'elsif'} = sub {
    my $self = shift;
    $self->fatal_parse_error('unexpected elsif');
    return [];
};

$BUILTINS{'else'} = sub {
    my $self = shift;
    $self->fatal_parse_error('unexpected else');
    return [];
};

$H{'for'} = [
    "for <var> (<commands>) { <commands> }\n",
    qq(    ex: for i (one two three) { print "<i>\\n" }\n)
];

$BUILTINS{'for'} = sub {
    my $self = shift;
    my $node = shift;

    # Get arguments from the AST node
    my $args = $self->get_args($node);
    $self->fatal_parse_error('bad arguments for for')
        if ( @{$args} < 3 );

    # Extract variable name, list to iterate over, and body
    my $var_expr  = $args->[0];
    my $list_expr = $args->[1];
    my $do_block  = $args->[2];

    # Get variable name
    my $var = join q(), @{ $self->expand_expression($var_expr) };

    # Get the list to iterate over
    my $result = $self->execute_expression($list_expr);

    # Create a new local scope
    unshift @LOCAL, {};

    # Set up iteration variables
    $LOCAL[0]->{index} = [1];
    $LOCAL[0]->{total} = [ scalar grep m{\S}, @{$result} ];

    my $rv = [];

    # Iterate through each item in the list
    for my $item ( @{$result} ) {
        next if ( $item !~ m{\S} );

        # Set the loop variable
        $LOCAL[0]->{$var} = [$item];

        # Execute the loop body
        $rv = $self->execute_ast_node($do_block);

        # Increment the counter
        $LOCAL[0]->{index}->[0]++;
    }

    # Remove the local scope
    shift @LOCAL;

    return $rv;
};

$H{'eval'} = [qq(eval "<commands>"\n)];

$BUILTINS{'eval'} = sub {
    my $self = shift;
    my $node = shift;

    # Get arguments from the AST node
    my $args = $self->get_args($node);
    $self->fatal_parse_error('bad arguments for eval')
        if ( @{$args} > 1 );

    my $rv = [];

    # If we have a command string to evaluate
    if ( @{$args} ) {

        # Get the command text
        my $text_expr = $args->[0];
        my $text      = join q(), @{ $self->expand_expression($text_expr) };

        # Parse the text into a new AST
        my $ast  = undef;
        my $okay = eval {
            my $tokens = $self->tokenize($text);
            $ast = $self->build_ast($tokens);
            return 1;
        };
        if ( not $okay ) {
            $self->fatal_parse_error("Error parsing eval string: $@");
        }

        # Execute the new AST
        $rv = $self->execute_ast_node($ast);
    }

    return $rv;
};

$H{'include'} = ["include <filename> [ <var>=<value> ... ]\n"];

$BUILTINS{'include'} = sub {
    my $self = shift;
    my $node = shift;

    # Get arguments from the AST node
    my $args = $self->get_args($node);
    $self->fatal_parse_error('bad arguments for include')
        if ( @{$args} < 1 );

    # Get the filename
    my $filename_expr = $args->[0];
    my $relative = join q(), @{ $self->expand_expression($filename_expr) };

    # Setup variables
    my %new_local = ();
    my @lines     = ();

    # Resolve path
    my $home   = $self->{configuration}->{home} || ( getpwuid $< )[7];
    my $prefix = join q(/), $home, '.tachikoma';
    my $path =
          $relative =~ m{^/}
        ? $relative
        : join q(/), $prefix, $relative;

    # Process any variable assignments (var=value pairs)
    if ( @{$args} > 1 ) {
        for ( my $i = 1; $i < @{$args}; $i++ )
        {    ## no critic (ProhibitCStyleForLoops)
            my $arg      = $args->[$i];
            my $arg_text = join q(), @{ $self->execute_expression($arg) };

            if ( $arg_text =~ m{^([[[:alpha:]]_]\w*)=(.*)$} ) {
                my ( $key, $value ) = ( $1, $2 );
                $new_local{$key} = $value;
            }
            else {
                $self->fatal_parse_error(
                    "Invalid variable assignment: $arg_text");
            }
        }
    }

    # Read the file
    open my $fh, '<', $path
        or $self->fatal_parse_error("couldn't open $path: $!");
    push @lines, $_ while (<$fh>);
    close $fh or die $!;

    # Determine which shell to use
    my $shell = undef;
    if ( $lines[0] eq "v1\n" ) {
        shift @lines;
        $shell = Tachikoma::Nodes::Shell->new;
        $shell->sink( $self->sink );
    }
    elsif ( $lines[0] eq "v2\n" ) {
        shift @lines;
        $shell = Tachikoma::Nodes::Shell2->new;
        $shell->sink( $self->sink );
    }
    else {
        shift @lines if ( $lines[0] eq "v3\n" );
        $shell = $self;
    }

    # Create a new scope with our variables
    unshift @LOCAL, \%new_local;

    # Process each line
    for my $line (@lines) {
        my $message = Tachikoma::Message->new;
        $message->[TYPE]    = TM_BYTESTREAM;
        $message->[FROM]    = '_stdin';
        $message->[PAYLOAD] = $line;
        $shell->fill($message);
    }

    # Remove the local scope
    shift @LOCAL;

    return [];
};

$H{'func'} = ["func <name> { <commands> }\n"];

$BUILTINS{'func'} = sub {
    my $self = shift;
    my $node = shift;

    # Get arguments from the AST node
    my $args      = $self->get_args($node);
    my $name      = q();
    my $func_body = undef;
    my $rv        = [];

    $self->fatal_parse_error('bad arguments for func')
        if ( @{$args} > 2 );

    # If we have arguments, process them
    if ( @{$args} > 0 ) {

        # First argument should be the function name
        $name = join q(), @{ $self->expand_expression( $args->[0] ) };

        # Second argument (if present) should be the function body
        if ( @{$args} ) {
            $func_body = $args->[1];
        }
    }

    # Define the function
    if ( length $name && defined $func_body ) {
        $self->{configuration}->{functions}->{$name} = $func_body;
        $self->{configuration}->{help}->{$name} = ["func $name { ... }\n"];
    }
    else {
        $self->fatal_parse_error('missing function name or body');
    }

    return $rv;
};

$H{'remote_func'} = ["remote_func [ <name> [ { <commands> } ] ]\n"];

$BUILTINS{'remote_func'} = sub {
    my $self = shift;
    my $node = shift;

    # Get arguments from the AST node
    my $args      = $self->get_args($node);
    my $name      = q();
    my $func_body = undef;
    my $rv        = [];

    $self->fatal_parse_error('bad arguments for remote_func')
        if ( @{$args} > 2 );

    # If we have arguments, process them
    if ( @{$args} > 0 ) {

        # First argument should be the function name
        $name = join q(), @{ $self->expand_expression( $args->[0] ) };

        # Second argument (if present) should be the function body
        if ( @{$args} > 1 ) {
            $func_body = $args->[1];
        }
    }

    # Send the function to a remote node
    if ( not $self->{validate} ) {
        $self->_send_command( 'remote_func', $name,
            $func_body ? nfreeze($func_body) : undef );
    }

    return $rv;
};

$H{'return'} = ["return <value>\n"];

$BUILTINS{'return'} = sub {
    my $self = shift;
    my $node = shift;

    # Get arguments from the AST node
    my $args = $self->get_args($node);
    $self->fatal_parse_error('bad arguments for return')
        if ( @{$args} > 1 );

    # Get the return value
    my $value = q();
    if ( @{$args} ) {
        $value = join q(), @{ $self->expand_expression( $args->[0] ) };
    }

    die "RV:$value\n";
};

$H{'die'} = ["die <value>\n"];

$BUILTINS{'die'} = sub {
    my $self = shift;
    my $node = shift;

    # Get arguments from the AST node
    my $args = $self->get_args($node);
    $self->fatal_parse_error('bad arguments for die')
        if ( @{$args} > 1 );

    # Get the die message
    my $value = q();
    if ( @{$args} ) {
        $value = join q(), @{ $self->expand_expression( $args->[0] ) };
    }

    die "DIE:$value\n";
};

$H{'confess'} = ["confess <value>\n"];

$BUILTINS{'confess'} = sub {
    my $self = shift;
    my $node = shift;

    # Get arguments from the AST node
    my $args = $self->get_args($node);
    $self->fatal_parse_error('bad arguments for confess')
        if ( @{$args} > 1 );

    # Get the confess message
    my $value = q();
    if ( @{$args} ) {
        $value = join q(), @{ $self->expand_expression( $args->[0] ) };
    }

    confess "CONFESS:$value\n";
};

$H{'on'} = ["on <node> <event> { <commands> }\n"];

$BUILTINS{'on'} = sub {
    my $self = shift;
    my $node = shift;

    # Get arguments from the AST node
    my $args = [ @{ $node->{args} // [] } ];

    # Extract node name, event name, and function body
    my $node_name = $self->get_fragmented_name($args);
    shift @{$args} while ( @{$args} and $args->[0]->{type} eq 'whitespace' );
    my $event_name = $self->expand_expression( shift @{$args} )->[0];
    shift @{$args} while ( @{$args} and $args->[0]->{type} eq 'whitespace' );
    my $func_body = shift @{$args};
    shift @{$args} while ( @{$args} and $args->[0]->{type} eq 'whitespace' );
    $self->fatal_parse_error('bad arguments for on')
        if ( not $func_body or @{$args} );

    # Send to the remote node, but only if not in validate mode
    if ( not $self->{validate} ) {
        $self->_send_command( 'on', "$node_name $event_name",
            nfreeze($func_body) );
    }

    return [];
};

$H{'chdir'} = [ "chdir [ <path> ]\n", "    alias: cd\n" ];

$BUILTINS{'chdir'} = sub {
    my $self = shift;
    my $node = shift;

    # Get arguments from the AST node
    my $args = $self->get_args($node);

    # Get the path argument
    my $path = join q(), map { @{ $self->expand_expression($_) } } @{$args};

    # Change directory
    my $cwd = $self->path;
    $self->path( $self->cd( $cwd, $path ) );
    $self->get_completions;

    return [];
};

$BUILTINS{'cd'} = $BUILTINS{'chdir'};

$H{'command_node'} = [
    "command_node <path> <command> [ <arguments> ]\n",
    "    alias: command, cmd\n"
];

$BUILTINS{'command_node'} = sub {
    my $self = shift;
    my $node = shift;

    # Get arguments from the AST node
    my $args    = [ @{ $node->{args} // [] } ];
    my $trimmed = $self->get_args($node);
    $self->fatal_parse_error('bad arguments for command_node')
        if ( @{$trimmed} < 2 );

    # Get path and command
    shift @{$args} while ( @{$args} and $args->[0]->{type} eq 'whitespace' );
    my $proto = join q(), map { @{ $self->expand_expression($_) } } @{$args};
    my ( $path, $cmd_name, $cmd_args ) = split q( ), $proto, 3;
    $self->fatal_parse_error('bad arguments for command_node')
        if ( not length $cmd_name );

    # Set up path context
    my $old_path  = $self->path;
    my $full_path = $old_path ? join q(/), $old_path, $path : $path;

    # Execute command in path context
    $self->path($full_path);    # set $message->[TO]
    $self->cwd($full_path);     # don't run functions with send_command()
    $self->_send_command( $cmd_name, $cmd_args );

    # Restore original path
    $self->path($old_path);
    $self->cwd(undef);
    return [];
};

$BUILTINS{'command'} = $BUILTINS{'command_node'};
$BUILTINS{'cmd'}     = $BUILTINS{'command_node'};

$H{'tell_node'} = [ "tell_node <path> <info>\n", "    alias: tell\n" ];

$BUILTINS{'tell_node'} = sub {
    my $self = shift;
    my $node = shift;

    # Get arguments from the AST node
    my $args    = [ @{ $node->{args} // [] } ];
    my $trimmed = $self->get_args($node);
    $self->fatal_parse_error('bad arguments for tell_node')
        if ( @{$trimmed} < 2 );

    # Get path and payload
    shift @{$args} while ( @{$args} and $args->[0]->{type} eq 'whitespace' );
    my $proto = join q(), map { @{ $self->expand_expression($_) } } @{$args};
    my ( $path, $payload ) = split q( ), $proto, 2;
    $self->fatal_parse_error('bad arguments for request_node')
        if ( not length $path );

    # Create and send message
    my $message = Tachikoma::Message->new;
    $message->type(TM_INFO);
    $message->from( $self->get_shared( 'message.from', 1 ) // '_responder' );
    $message->stream( $self->get_shared( 'message.stream', 1 ) // q() );
    $message->id( $self->message_id // q() );
    $message->to( $self->prefix($path) );
    $message->payload( $payload // q() );

    return [ $self->sink->fill($message) ];
};

$BUILTINS{'tell'} = $BUILTINS{'tell_node'};

$H{'request_node'} =
    [ "request_node <path> <request>\n", "    alias: request\n" ];

$BUILTINS{'request_node'} = sub {
    my $self = shift;
    my $node = shift;

    # Get arguments from the AST node
    my $args    = [ @{ $node->{args} // [] } ];
    my $trimmed = $self->get_args($node);
    $self->fatal_parse_error('bad arguments for request_node')
        if ( @{$trimmed} < 2 );

    # Get path and payload
    shift @{$args} while ( @{$args} and $args->[0]->{type} eq 'whitespace' );
    my $proto = join q(), map { @{ $self->expand_expression($_) } } @{$args};
    my ( $path, $payload ) = split q( ), $proto, 2;
    $self->fatal_parse_error('bad arguments for request_node')
        if ( not length $path );

    # Create and send message
    my $message = Tachikoma::Message->new;
    $message->type(TM_REQUEST);
    $message->from( $self->get_shared( 'message.from', 1 ) // '_responder' );
    $message->stream( $self->get_shared( 'message.stream', 1 ) // q() );
    $message->id( $self->message_id // q() );
    $message->to( $self->prefix($path) );
    $message->payload( $payload // q() );

    return [ $self->sink->fill($message) ];
};

$BUILTINS{'request'} = $BUILTINS{'request_node'};

$H{'send_node'} = [ "send_node <path> <bytes>\n", "    alias: send\n" ];

$BUILTINS{'send_node'} = sub {
    my $self = shift;
    my $node = shift;

    # Get arguments from the AST node
    my $args    = [ @{ $node->{args} // [] } ];
    my $trimmed = $self->get_args($node);
    $self->fatal_parse_error('bad arguments for send_node')
        if ( @{$trimmed} < 2 );

    # Get path and payload
    my $proto = join q(), map { @{ $self->expand_expression($_) } } @{$args};
    my ( $path, $payload ) = split q( ), $proto, 2;
    $self->fatal_parse_error('bad arguments for send_node')
        if ( not length $path );

    # create and send message
    my $message = Tachikoma::Message->new;
    $message->type(TM_BYTESTREAM);
    $message->from( $self->get_shared( 'message.from', 1 ) // '_responder' );
    $message->stream( $self->get_shared( 'message.stream', 1 ) );
    $message->id( $self->message_id // q() );
    $message->to( $self->prefix($path) );
    $message->payload( $payload // q() );

    return [ $self->sink->fill($message) ];
};

$BUILTINS{'send'} = $BUILTINS{'send_node'};

$H{'send_hash'} = [ "send_hash <path> <json>\n", ];

$BUILTINS{'send_hash'} = sub {
    my $self = shift;
    my $node = shift;
    die "error: no json support\n" if ( not $USE_JSON );

    # get arguments from the ast node
    my $args    = [ @{ $node->{args} // [] } ];
    my $trimmed = $self->get_args($node);
    $self->fatal_parse_error('bad arguments for send_hash')
        if ( @{$args} < 2 );

    # get path and json payload
    shift @{$args} while ( @{$args} and $args->[0]->{type} eq 'whitespace' );
    my $proto = join q(), map { @{ $self->expand_expression($_) } } @{$args};
    my ( $path, $payload ) = split q( ), $proto, 2;
    $self->fatal_parse_error('bad arguments for send_hash')
        if ( not length $path );

    # create and send message
    my $json    = JSON->new;
    my $message = Tachikoma::Message->new;
    $message->type(TM_STORABLE);
    $message->from( $self->get_shared( 'message.from', 1 ) // '_responder' );
    $message->stream( $self->get_shared( 'message.stream', 1 ) );
    $message->id( $self->message_id // q() );
    $message->to( $self->prefix($path) );
    $message->payload( $json->decode($payload) );

    return [ $self->sink->fill($message) ];
};

$H{'bytestream'} = [ "bytestream <path>\n", ];

$BUILTINS{'bytestream'} = sub {
    my $self = shift;
    my $node = shift;

    # Get arguments from the AST node
    my $args = $self->get_args($node);
    $self->fatal_parse_error('bad arguments for bytestream')
        if ( @{$args} > 1 );

    # Get the path argument
    my $path = join q(), map { @{ $self->expand_expression($_) } } @{$args};

    # Set up bytestream mode
    my $cwd = $self->path;
    $self->cwd($cwd);    # store cwd
    $self->path( $self->cd( $cwd, $path ) );
    $self->mode('bytestream');

    return [];
};

$H{'ping'} = ["ping [ <path> ]\n"];

$BUILTINS{'ping'} = sub {
    my $self = shift;
    my $node = shift;

    # Get arguments from the AST node
    my $args = $self->get_args($node);
    $self->fatal_parse_error('bad arguments for ping')
        if ( @{$args} > 1 );

    # Get the path argument
    my $path = join q(), map { @{ $self->expand_expression($_) } } @{$args};

    # Create and send message
    my $message = Tachikoma::Message->new;
    $message->type(TM_PING);
    $message->from( $self->get_shared( 'message.from', 1 ) // '_responder' );
    $message->to( $self->prefix($path) );
    $message->payload($Tachikoma::Right_Now);

    return [ $self->sink->fill($message) ];
};

$H{'pwd'} = ["pwd\n"];

$BUILTINS{'pwd'} = sub {
    my $self = shift;
    my $node = shift;

    # Get arguments from the AST node
    my $args = $self->get_args($node);
    $self->fatal_parse_error('bad arguments for pwd')
        if ( @{$args} > 0 );

    $self->_send_command( 'pwd', $self->path );

    return [];
};

$H{'debug_level'} = [ "debug_level [ <level> ]\n", "    levels: 0, 1, 2\n" ];

$BUILTINS{'debug_level'} = sub {
    my $self = shift;
    my $node = shift;

    # Get arguments from the AST node
    my $args = $self->get_args($node);
    $self->fatal_parse_error('bad arguments for debug_level')
        if ( @{$args} > 1 );

    # Get the level argument or toggle
    my $level = not $self->configuration->debug_level;
    if ( @{$args} ) {
        $level = join q(), map { @{ $self->expand_expression($_) } } @{$args};
    }

    $self->configuration->debug_level($level);
    return [];
};

$H{'show_parse'} = [ "show_parse [ <value> ]\n", "    values: 0, 1\n" ];

$BUILTINS{'show_parse'} = sub {
    my $self = shift;
    my $node = shift;

    # Get arguments from the AST node
    my $args = $self->get_args($node);
    $self->fatal_parse_error('bad arguments for show_parse')
        if ( @{$args} > 1 );

    # Get the value argument or toggle
    my $value = not $self->show_parse;
    if ( @{$args} ) {
        $value = join q(), map { @{ $self->expand_expression($_) } } @{$args};
    }

    $self->show_parse($value);
    return [];
};

$H{'show_commands'} = [ "show_commands [ <value> ]\n", "    values: 0, 1\n" ];

$BUILTINS{'show_commands'} = sub {
    my $self = shift;
    my $node = shift;

    # Get arguments from the AST node
    my $args = $self->get_args($node);
    $self->fatal_parse_error('bad arguments for show_commands')
        if ( @{$args} > 1 );

    # Get the value argument or toggle
    my $value = not $self->show_commands;
    if ( @{$args} ) {
        $value = join q(), map { @{ $self->expand_expression($_) } } @{$args};
    }

    $self->show_commands($value);
    return [];
};

$H{'want_reply'} = [ "want_reply [ <value> ]\n", "    values: 0, 1\n" ];

$BUILTINS{'want_reply'} = sub {
    my $self = shift;
    my $node = shift;

    # Get arguments from the AST node
    my $args = $self->get_args($node);
    $self->fatal_parse_error('bad arguments for want_reply')
        if ( @{$args} > 1 );

    # Get the value argument or toggle
    my $value = not $self->want_reply;
    if ( @{$args} ) {
        $value = join q(), map { @{ $self->expand_expression($_) } } @{$args};
    }

    $self->want_reply($value);
    return [];
};

$H{'respond'} = ["respond\n"];

$BUILTINS{'respond'} = sub {
    my $self = shift;
    my $node = shift;

    # Get arguments from the AST node
    my $args = $self->get_args($node);
    $self->fatal_parse_error('bad arguments for respond')
        if ( @{$args} > 0 );

    Tachikoma->nodes->{_responder}->ignore(undef);
    return [];
};

$H{'ignore'} = ["ignore\n"];

$BUILTINS{'ignore'} = sub {
    my $self = shift;
    my $node = shift;

    # Get arguments from the AST node
    my $args = $self->get_args($node);
    $self->fatal_parse_error('bad arguments for ignore')
        if ( @{$args} > 0 );

    Tachikoma->nodes->{_responder}->ignore('true');
    return [];
};

$H{'sleep'} = ["sleep <seconds>\n"];

$BUILTINS{'sleep'} = sub {
    my $self = shift;
    my $node = shift;

    # Get arguments from the AST node
    my $args = $self->get_args($node);
    $self->fatal_parse_error('bad arguments for sleep')
        if ( @{$args} != 1 );

    # Get the seconds value
    my $seconds = join q(),
        map { @{ $self->expand_expression($_) } } @{$args};

    $self->fatal_parse_error("bad arguments for sleep: $seconds")
        if ( $seconds =~ m{\D} );

    sleep $seconds;
    return [];
};

$H{'shell'} = ["shell\n"];

$BUILTINS{'shell'} = sub {
    my $self = shift;
    my $node = shift;

    # Get arguments from the AST node
    my $args = $self->get_args($node);
    $self->fatal_parse_error('bad arguments for shell')
        if ( @{$args} > 0 );

    $self->is_attached('true');
    return [];
};

$H{'exit'} = ["exit [ <value> ]\n"];

$BUILTINS{'exit'} = sub {
    my $self = shift;
    my $node = shift;

    # Get arguments from the AST node
    my $args = $self->get_args($node);
    $self->fatal_parse_error('bad arguments for exit')
        if ( @{$args} > 1 );

    # Get exit value (default to 0)
    my $value = 0;
    if ( @{$args} ) {
        $value = join q(), map { @{ $self->expand_expression($_) } } @{$args};
    }

    if ( $value =~ m{\D} ) {
        $self->stderr(qq(ERROR: bad arguments for exit: "$value"));
        $value = 1;
    }

    $Tachikoma::Nodes{_stdin}->close_filehandle
        if ( $Tachikoma::Nodes{_stdin} );

    exit $value;
};

sub send_command {    ## no critic (ProhibitExcessComplexity)
    my $self = shift;
    my $node = shift or return [];
    my $cwd  = $self->{cwd};         # set by command_node
    my $rv   = [];

    # Handle different node types
    if ( $node->{type} eq 'command_list' ) {

        # Process each command in the list
        for my $cmd ( @{ $node->{commands} } ) {
            my $cmd_result = $self->send_command($cmd);
            push @{$rv}, @{$cmd_result} if $cmd_result;
        }
    }
    elsif ( $node->{type} eq 'command' or $node->{type} eq 'variable' ) {
        my $name = $node->{name};
        $name = $SHARED{$name} if ( $node->{type} eq 'variable' );

        # Check for builtin commands
        if ( $BUILTINS{$name} ) {
            $rv = $BUILTINS{$name}->( $self, $node );
        }

        # Check for user-defined functions
        elsif ( $self->{configuration}->{functions}->{$name} and not $cwd ) {
            $rv = $self->_call_function_ast( $name, $node );
        }

        # Fall back to system commands
        else {
            my $line = $name;

            # Process arguments
            if ( @{ $node->{args} } ) {
                my @arg_values = ();
                for my $arg ( @{ $node->{args} } ) {
                    my $arg_val = $self->expand_expression($arg);
                    push @arg_values, @{$arg_val} if $arg_val;
                }
                $line .= q( ) . join q(), @arg_values if @arg_values;
            }

            # Execute command if it's not empty
            $rv = $self->_send_command( split q( ), $line, 2 )
                if ( $line =~ m{\S} );
        }
    }
    elsif ( $node->{type} eq 'block' || $node->{type} eq 'bracket' ) {

        # Execute blocks directly
        $rv = $self->execute_ast_node($node);
    }
    elsif ( $EXPRESSIONS{ $node->{type} } ) {

        # Execute expressions
        $rv = $self->execute_expression($node);
    }
    elsif ( $node->{type} eq 'string1' ) {
        my $value = $node->{name};
        $value =~ s{(?<!\\)<([^<>]+)>}{$SHARED{$1}}g;
        $value =~ s/\\([<>])/$1/g;
        $value =~ s/\\e/\e/g;
        $value =~ s/\\n/\n/g;
        $value =~ s/\\r/\r/g;
        $value =~ s/\\t/\t/g;
        $value =~ s/\\(")/"/g;
        $value =~ s/\\\\/\\/g;
        $rv = [$value];
    }

    return $rv;
}

sub execute_env_assignment {
    my $self   = shift;
    my $node   = shift;
    my $name   = join q(), @{ $self->execute_expression( $node->{name} ) };
    my $op     = $node->{operator};
    my $values = $self->execute_expression( $node->{value} );
    my $hash   = \%ENV;
    my $rv     = [];
    if ( length $op ) {

        # Perform variable operation with operator
        $rv = $self->operate_env( $hash, $name, $op, $values );
    }
    elsif ( length $name ) {

        # Get environment variable value
        $hash->{$name} //= q();
        $rv = [ $hash->{$name} ];
    }
    else {
        # Display all environment variables
        my $output = q();
        for my $var_name ( sort keys %{$hash} ) {
            my $line = "$var_name=" . ( $hash->{$var_name} // q() );
            chomp $line;
            $output .= "$line\n";
        }
        $rv = [$output];
    }

    return $rv;
}

sub execute_var_assignment {
    my $self   = shift;
    my $node   = shift;
    my $name   = join q(), @{ $self->execute_expression( $node->{name} ) };
    my $op     = $node->{operator};
    my $values = $self->execute_expression( $node->{value} );
    my $hash   = $self->{configuration}->{var};
    my $rv     = [];
    if ( length $op ) {

        # Perform variable operation with operator
        $rv = $self->operate( $hash, $name, $op, $values );
    }
    elsif ( length $name ) {

        # Get variable value
        $hash->{$name} //= q();
        if ( ref $hash->{$name} ) {
            $rv = $hash->{$name};
        }
        else {
            $rv = [ $hash->{$name} ];
        }
    }
    else {
        # Display all global variables
        my $output = q();
        for my $var_name ( sort keys %{$hash} ) {
            my $line = "$var_name=";
            if ( ref $hash->{$var_name} ) {
                $line
                    .= '["'
                    . join( q(", "), grep m{\S}, @{ $hash->{$var_name} } )
                    . '"]';
            }
            else {
                $line .= $hash->{$var_name} // q();
            }
            chomp $line;
            $output .= "$line\n";
        }

        # Return string
        $rv = [$output];
    }

    return $rv;
}

sub execute_local_assignment {
    my $self   = shift;
    my $node   = shift;
    my $name   = join q(), @{ $self->execute_expression( $node->{name} ) };
    my $op     = $node->{operator};
    my $values = $self->execute_expression( $node->{value} );
    my $hash   = $LOCAL[0];
    my $rv     = [];
    if ( length $op ) {
        $hash->{$name} = $self->get_local($name);

        # Perform variable operation with operator
        $rv = $self->operate( $hash, $name, $op, $values );
    }
    elsif ( length $name ) {

        # Get variable value
        $hash->{$name} = $self->get_local($name);
        $hash->{$name} //= q();
        if ( ref $hash->{$name} ) {
            $rv = $hash->{$name};
        }
        else {
            $rv = [ $hash->{$name} ];
        }
    }
    else {
        # Display all local variables by layer
        my $output = q();
        my $layer  = 0;
        for my $scope_hash (@LOCAL) {
            push @{$rv}, sprintf "### LAYER %d:\n", $layer++;
            for my $var_name ( sort keys %{$scope_hash} ) {
                my $line = "$var_name=";
                if ( ref $scope_hash->{$var_name} ) {
                    $line .= '["'
                        . join( q(", "),
                        grep m{\S}, @{ $scope_hash->{$var_name} } )
                        . '"]';
                }
                else {
                    $line .= $scope_hash->{$var_name} // q();
                }
                chomp $line;
                $output .= "$line\n";
            }
            $output .= "\n" if $layer < @LOCAL;
        }
        $rv = [$output];
    }
    return $rv;
}

sub execute_assignment {
    my $self = shift;
    my $node = shift;
    my $name = $node->{name};
    my $op   = $node->{operator};
    my $values =
        defined( $node->{value} )
        ? $self->execute_expression( $node->{value} )
        : undef;
    my $hash = $self->get_local_hash($name);
    if ($hash) {
        $self->operate( $hash, $name, $op, $values );
    }
    elsif ( exists $self->{configuration}->{var}->{$name} ) {
        $self->operate( $self->{configuration}->{var}, $name, $op, $values );
    }
    else {
        $self->fatal_parse_error("no such variable: $name");
    }
    return;
}

sub operate {
    my ( $self, $hash, $key, $op, $values ) = @_;
    my $rv = [];
    if ( $values and @{$values} ) {
        my $v = $self->operate_with_value( $hash, $key, $op, $values );
        if ( @{$v} > 1 ) {
            $hash->{$key} = $v;
        }
        else {
            $hash->{$key} = $v->[0] // q();
        }
    }
    elsif ( length $op ) {
        my $v = $hash->{$key};
        $v = $v->[0] if ( ref $v );
        $v = 0       if ( not defined $v or not length $v );
        if    ( $op eq q(=) )  { delete $hash->{$key}; }
        elsif ( $op eq q(++) ) { $v++; $hash->{$key} = $v; }
        elsif ( $op eq q(--) ) { $v--; $hash->{$key} = $v; }
        else { $self->fatal_parse_error("bad arguments: $op"); }
    }
    else {
        $self->fatal_parse_error('internal parser error');
    }
    return $rv;
}

sub operate_env {
    my ( $self, $hash, $key, $op, $values ) = @_;
    my $rv = [];
    if ( $values and @{$values} ) {
        my $v = $self->operate_with_value( $hash, $key, $op, $values );
        $hash->{$key} = join q(), @{$v};
    }
    elsif ( length $op ) {
        my $v = $hash->{$key};
        $v = $v->[0] if ( ref $v );
        $v = 0       if ( not defined $v or not length $v );
        if    ( $op eq q(=) )  { delete $hash->{$key}; }
        elsif ( $op eq q(++) ) { $v++; $hash->{$key} = $v; }
        elsif ( $op eq q(--) ) { $v--; $hash->{$key} = $v; }
        else { $self->fatal_parse_error("bad arguments: $op"); }
    }
    else {
        $self->fatal_parse_error('internal parser error');
    }
    return $rv;
}

sub operate_with_value {    ## no critic (ProhibitExcessComplexity)
    my ( $self, $hash, $key, $op, $values ) = @_;
    my $v = $hash->{$key};
    $v = []   if ( not defined $v );
    $v = [$v] if ( not ref $v );
    shift @{$values} while ( @{$values} and $values->[0]  =~ m{^\s+$} );
    pop @{$values}   while ( @{$values} and $values->[-1] =~ m{^\s+$} );
    my $joined = join q(), @{$values};
    if    ( $op eq q(=) )            { $v = $values; }
    elsif ( $op eq q(.=) and @{$v} ) { push @{$v}, q( ), @{$values} }
    elsif ( $op eq q(.=) )           { push @{$v}, @{$values} }
    elsif ( $op eq q(+=) )           { $v->[0] ||= 0; $v->[0] += $joined; }
    elsif ( $op eq q(-=) )           { $v->[0] ||= 0; $v->[0] -= $joined; }
    elsif ( $op eq q(*=) )           { $v->[0] ||= 0; $v->[0] *= $joined; }
    elsif ( $op eq q(/=) )           { $v->[0] ||= 0; $v->[0] /= $joined; }
    elsif ( $op eq q(//=) ) { $v = $values if ( not @{$v} ); }
    elsif ( $op eq q(||=) ) { $v = $values if ( not join q(), @{$v} ); }
    else  { $self->fatal_parse_error("invalid operator: $op"); }
    return $v;
}

# New method to handle function calls with AST
sub _call_function_ast {
    my $self      = shift;
    my $name      = shift;
    my $node      = shift;
    my %arguments = ();

    # Set up arguments
    $arguments{'0'} = $name;

    # Process command arguments
    my $args   = [ @{ $node->{args} // [] } ];
    my @values = ();
    my $j      = 1;
    pop @{$args} while ( @{$args} and $args->[-1]->{type} eq 'whitespace' );
    for my $i ( 0 .. $#{$args} ) {
        my $arg_val = $self->expand_expression( $args->[$i] );
        push @values, @{$arg_val};
        $arguments{ $j++ } = $arg_val
            if ( $args->[$i]->{type} ne 'whitespace' );
    }
    $arguments{q(@)} = \@values;
    $arguments{'_C'} = $j - 1;

    # Call the function with the new argument structure
    return $self->call_function( $name, \%arguments );
}

sub call_function {
    my $self       = shift;
    my $name       = shift;
    my $new_local  = shift // {};
    my $rv         = [];
    my $stack_size = $#LOCAL;

    # Set up the new local scope
    unshift @LOCAL, $new_local;

    # Get the function body AST
    my $func_body = $self->{configuration}->{functions}->{$name};

    # Execute the function body with error handling
    my $okay = eval {
        $rv = $self->execute_ast_node($func_body);
        return 1;
    };

    # Restore the original scope
    shift @LOCAL while ( $#LOCAL > $stack_size );

    # Handle any errors
    if ( not $okay ) {
        my $trap = $@ || 'call_function: unknown error';
        chomp $trap;
        my ( $type, $value ) = split m{:}, $trap, 2;

        if ( $type eq 'RV' ) {

            # Handle return value
            $rv = [$value] if ( defined $value );
        }
        elsif ( $type eq 'DIE' ) {

            # Handle die command
            $value .= " in function $name\n" if ( $trap !~ m{\n} );
            die $value;
        }
        else {
            # Handle other errors
            die "$trap in function $name\n";
        }
    }

    return $rv;
}

sub _send_command {
    my $self      = shift;
    my $name      = shift;
    my $arguments = shift // q();
    my $payload   = shift;
    my $path      = shift;
    my $from      = $self->get_shared( 'message.from', 1 );
    my $message   = $self->command( $name, $arguments, $payload );
    $message->type( TM_COMMAND | TM_NOREPLY )
        if ( not length $from and not $self->{want_reply} );
    $message->from( $from // '_responder' );
    $message->to( $self->prefix($path) );
    $message->id( $self->message_id // q() );
    $self->dirty($name);
    $self->stderr("+ $name $arguments") if ( $self->{show_commands} );
    return [ $self->sink->fill($message) // q() ];
}

sub callback {    ## no critic (ProhibitExcessComplexity)
    my $self      = shift;
    my $id        = shift;
    my $options   = shift;
    my $callbacks = $self->callbacks;
    my $rv        = undef;

    if ( $callbacks->{$id} ) {
        my $callback = $callbacks->{$id};

        # Handle pipe callback specifically
        if ( ref $callback eq 'HASH' && $callback->{type} eq 'pipe' ) {
            my @pipe_funcs = @{ $callback->{value} };
            my $first_func = shift @pipe_funcs;

            # Set up arguments for the first function in the pipe
            my %arguments = ();
            $arguments{'0'} = $options->{event};
            if ( not $options->{error} ) {
                $arguments{q(1)}      = $options->{payload};
                $arguments{q(@)}      = $options->{payload};
                $arguments{q(_C)}     = 1;
                $arguments{q(_ERROR)} = q();
            }
            else {
                $arguments{q(1)}      = q();
                $arguments{q(@)}      = q();
                $arguments{q(_C)}     = 0;
                $arguments{q(_ERROR)} = $options->{payload};
            }
            $arguments{q(response.from)} = $options->{from};

     # Execute first function and set up next callback if more functions exist
            my $stack_size = $#LOCAL;
            unshift @LOCAL, \%arguments;
            $self->message_id(undef);

            if (@pipe_funcs) {
                my $next_id = $self->msg_counter;
                $self->message_id($next_id);
                $self->callbacks->{$next_id} =
                    @pipe_funcs > 1
                    ? { type => 'pipe', value => \@pipe_funcs }
                    : $pipe_funcs[0];
            }

            my $okay = eval {
                $self->execute_ast_node($first_func);
                return 1;
            };

            shift @LOCAL while ( $#LOCAL > $stack_size );
            $self->message_id(undef);

            if ( not $okay ) {
                my $trap = $@ || 'pipe callback failed: unknown error';
                $self->stderr($trap);
            }

            $rv = $okay;
        }
        else {
            # Handle regular callbacks as before
            my %arguments = ();
            $arguments{'0'} = $options->{event};
            if ( not $options->{error} ) {
                $arguments{q(1)}      = $options->{payload};
                $arguments{q(@)}      = $options->{payload};
                $arguments{q(_C)}     = 1;
                $arguments{q(_ERROR)} = q();
            }
            else {
                $arguments{q(1)}      = q();
                $arguments{q(@)}      = q();
                $arguments{q(_C)}     = 0;
                $arguments{q(_ERROR)} = $options->{payload};
            }
            $arguments{q(response.from)} = $options->{from};
            my $stack_size = $#LOCAL;
            unshift @LOCAL, \%arguments;
            $self->message_id(undef);
            my $okay = eval {
                my $result = $self->execute_ast_node($callback);
                if (    $Tachikoma::Nodes{_stdin}
                    and
                    $Tachikoma::Nodes{_stdin}->isa('Tachikoma::Nodes::TTY') )
                {
                    my $output = join q(), @{$result};
                    syswrite STDOUT, $output or die if ( length $output );
                }
                return 1;
            };
            shift @LOCAL while ( $#LOCAL > $stack_size );
            $rv = $okay;
            if ( not $okay ) {
                my $trap = $@ || 'callback failed: unknown error';
                chomp $trap;
                my ( $type, $value ) = split m{:}, $trap, 2;
                if ( $type eq 'RV' ) {
                    $rv = [$value] if ( defined $value );
                }
                else {
                    $self->stderr($trap);
                }
            }
        }
    }
    else {
        $self->stderr("WARNING: couldn't find callback for id $id");
    }
    return $rv;
}

sub get_completions {
    my $self = shift;
    return
        if ( not $Tachikoma::Nodes{_stdin}
        or not $Tachikoma::Nodes{_stdin}->isa('Tachikoma::Nodes::TTY')
        or not $Tachikoma::Nodes{_stdin}->use_readline );
    my $message = $self->command('help');
    $message->[TYPE] |= TM_COMPLETION;
    $message->[FROM] = '_responder';
    $message->[TO]   = $self->path;
    $self->sink->fill($message);
    $message = $self->command( 'ls', '-a' );
    $message->[TYPE] |= TM_COMPLETION;
    $message->[FROM] = '_responder';
    $message->[TO]   = $self->path;
    $self->sink->fill($message);
    $self->dirty(undef);
    return;
}

sub report_error {
    my $self = shift;
    if (@_) {
        my $error = shift;
        $self->{errors}++;

        # check prefix for bot support
        $self->{validate} = 1
            if ( not $self->{isa_tty} and not $self->{prefix} );
        $self->stderr($error);
    }
    return;
}

sub name {
    my $self = shift;
    if (@_) {
        die "ERROR: named Shell nodes are not allowed\n";
    }
    return $self->{name};
}

sub callbacks {
    my $self = shift;
    if (@_) {
        $self->{callbacks} = shift;
    }
    return $self->{callbacks};
}

sub cwd {
    my $self = shift;
    if (@_) {
        $self->{cwd} = shift;
    }
    return $self->{cwd};
}

sub dirty {
    my $self = shift;
    if (@_) {
        my $name  = shift;
        my %dirty = map { $_ => 1 } qw(
            listen_inet listen_unix
            connect_inet disconnect_inet
            connect_unix disconnect_unix
            make_node make
            make_connected_node make_x
            move_node mv
            remove_node rm
            start_job start stop_job stop
            maintain_job maintain sudo_job sudo
            maintain_sudo_job maintain_sudo
            in at every
            add_branch add
            command cmd
        );
        $self->{dirty} = $name ? $dirty{$name} : undef;
    }
    return $self->{dirty};
}

sub mode {
    my $self = shift;
    if (@_) {
        $self->{mode} = shift;
        if ( $Tachikoma::Nodes{_stdin} ) {
            if ( $self->{mode} ne 'bytestream' ) {

                # print STDERR "un-ignoring EOF\n";
                $Tachikoma::Nodes{_stdin}->on_EOF('close');
            }
            else {
                # print STDERR "ignoring EOF\n";
                $Tachikoma::Nodes{_stdin}->on_EOF('send');
            }
        }
    }
    return $self->{mode};
}

sub message_id {
    my $self = shift;
    my $rv   = undef;
    if (@_) {
        $self->{message_id} = shift;
    }
    return $self->{message_id};
}

sub parse_buffer {
    my $self = shift;
    if (@_) {
        $self->{parse_buffer} = shift;
    }
    return $self->{parse_buffer};
}

sub show_parse {
    my $self = shift;
    if (@_) {
        $self->{show_parse} = shift;
    }
    return $self->{show_parse};
}

sub get_fragmented_name {
    my $self = shift;
    my $args = shift;

    # Extract name from arguments
    my $name = @{$args} ? q() : undef;
    while ( @{$args} and $args->[0]->{type} ne 'whitespace' ) {
        $name .= $self->expand_expression( shift @{$args} )->[0];
    }

    return $name;
}

sub get_args {
    my $self = shift;
    my $node = shift;
    my $args =
        [ grep { $_->{type} ne 'whitespace' } @{ $node->{args} // [] } ];
    return $args;
}

sub token_index {
    my $self = shift;
    if (@_) {
        $self->{token_index} = shift;
    }
    return $self->{token_index};
}

sub tokens {
    my $self = shift;
    if (@_) {
        $self->{tokens} = shift;
    }
    return $self->{tokens};
}

sub help_topics {
    return \%H;
}

sub builtins {
    return \%BUILTINS;
}

sub msg_counter {
    my $self = shift;
    $MSG_COUNTER = ( $MSG_COUNTER + 1 ) % $Tachikoma::Max_Int;
    return sprintf '%d:%010d', $Tachikoma::Now, $MSG_COUNTER;
}

sub set_local {    ## no critic (RequireArgUnpacking)
    my $self = shift;
    unshift @LOCAL, @_;
    return;
}

sub restore_local {
    my $self = shift;
    shift @LOCAL;
    return;
}

sub get_shared {
    my $self   = shift;
    my $key    = shift;
    my $silent = shift;
    my $rv     = undef;
    for my $hash (@LOCAL) {
        next if ( not exists $hash->{$key} );
        $rv = $hash->{$key};
        last;
    }
    if ( not defined $rv ) {
        if ( defined Tachikoma->configuration->{var}->{$key} ) {
            $rv = Tachikoma->configuration->{var}->{$key};
        }
        elsif ( not $silent ) {
            print {*STDERR} "WARNING: use of uninitialized value <$key>\n";
        }
    }
    return $rv;
}

sub get_local {
    my $self = shift;
    my $key  = shift;
    for my $hash (@LOCAL) {
        return $hash->{$key} if ( exists $hash->{$key} );
    }
    return;
}

sub get_local_hash {
    my $self = shift;
    my $key  = shift;
    for my $hash (@LOCAL) {
        return $hash if ( exists $hash->{$key} );
    }
    return;
}

sub TIEHASH {
    my $self = shift;
    my $node = {};
    bless $node, $self;
    return $node;
}

sub FETCH {
    my $self = shift;
    my $key  = shift;
    my $rv   = $self->get_shared($key);
    return ref $rv ? join q(), @{$rv} : $rv // q();
}

1;
