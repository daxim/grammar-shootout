#!/usr/bin/env perl
use 5.024;
use Capture::Tiny qw(capture);
use File::Slurper qw(read_binary write_binary);
use Marpa::R2 qw();
use Moops;
use Kavorka qw(fun);
use Test::More import => [qw(diag done_testing)];
use Test::Deep qw(cmp_set);
use Tie::Hash::Indexed qw();

class Metagrammar {
    method parse(Str :$input) {
        my $r = Marpa::R2::Scanless::R->new({
            grammar => Marpa::R2::Scanless::G->new({
                bless_package => 'Metagrammar',
                source => \<<~'',
                    :default ::= action => [values] bless => ::lhs
                    lexeme default = action => [values] latm => 1 bless => ::name
                    :discard ~ whitespace
                    whitespace ~ [\s]+
                    Grammar ::= Rule+
                    Rule ::= Nonterminal Equal Symplus
                    Symplus ::= Sym+
                    Sym ::= Nonterminal | Terminal
                    Nonterminal ~ [A-Za-z]+
                    Terminal ~ [\x{27}] Unquote [\x{27}] | 'ε'
                    Unquote ~ [^']+ #'
                    Equal ~ '⩴' | '→'

            })
        });
        $r->read(\$input);
        return $r->value->$*;
    }
    method Equal(@values) {}
    method Grammar(@values) {
        my @r = map {
            ref($_)
                ? Metagrammar->can($_->{type})->($_->{type}, $_->{values}->@*)
                : $_
        } @values;
        my $start = $r[0][0];
        tie my %r, 'Tie::Hash::Indexed';
        for my $r (@r) {
            my $name = $r->[0];
            push $r{$name}->@*, $r->[1];
        }
        my $ret = "start:\n\t$start" . ' { shift; use JSON::MaybeXS qw(encode_json); print encode_json $_[0] };' . "\n";
        for my $k (keys %r) {
            $ret .= "$k:\n";
            my @syms;
            for my $syms ($r{$k}->@*) {
                my $p = "\t" . join ' ', $syms->@*;
                $p .= sprintf "\t{ shift; ['%s', (scalar \@_) ? \@_ : undef] }", $k;
                push @syms, $p;
            }
            $ret .= join " |\n", @syms;
            $ret .= ";\n";
        };
        return $ret;
    }
    method Nonterminal(@values) {
        return shift @values;
    }
    method Rule(@values) {
        my @r = map {
            ref($_)
                ? Metagrammar->can($_->{type})->($_->{type}, $_->{values}->@*)
                : $_
        } @values;
        return \@r;
    }
    method Sym(@values) {
        return [map {
            ref($_)
                ? Metagrammar->can($_->{type})->($_->{type}, $_->{values}->@*)
                : $_
        } @values]->[0];
    }
    method Symplus(@values) {
        return [map {
            ref($_)
                ? Metagrammar->can($_->{type})->($_->{type}, $_->{values}->@*)
                : $_
        } @values];
    }
    method Terminal(@values) {
        $values[0] = '' if 'ε' eq $values[0];
        return $values[0];
    }
}

fun visit($v) {
    my $r = { values => [], type => ref($v) =~ s/^Metagrammar:://r };
    push $r->{values}->@*, map { ref($_) ? visit($_) : $_ } $v->@*;
    return $r;
}

fun MAIN(Str $grammar_name) {
    my $grammar = read_binary "grammars/$grammar_name";
    my $v = visit(Metagrammar->new->parse(input => $grammar));
    my $generated = Metagrammar->can($v->{type})->($v->{type}, $v->{values}->@*);
    mkdir 'generated';
    my $template = <<~'...';
        %strict
        %tree
        %%
        __GRAMMAR__
        %%
        ...

    write_binary(
        "generated/${grammar_name}__Parse-Eyapp.eyp",
        $template =~ s/__GRAMMAR__/$generated/r
    );
    system 'eyapp',
        '-o', "generated/${grammar_name}__Parse-Eyapp.pl",
        '-m', ("${grammar_name}__Parse_Eyapp" =~ s/-/_/gr),
        '-C', "generated/${grammar_name}__Parse-Eyapp.eyp"
    and die $?;
    my @input = split /\n/, read_binary "input/$grammar_name";
    my @output = split /\n/, read_binary "output/$grammar_name";
    while (my ($idx, $input) = each @input) {
        my $status;
        my ($out, $err) = capture {
            open my $proc, '|-', $^X, "generated/${grammar_name}__Parse-Eyapp.pl";
            $proc->print($input);
            close $proc;
            $status = $?;
        };
        cmp_set(
            [split '␞', $out],
            [split '␞', $output[$idx]],
            "${grammar_name}__Parse-Eyapp $input"
        ) or diag $err;
    }
    done_testing;
}

die "usage: $0 grammar_name\n" unless $ARGV[0];
MAIN($ARGV[0] =~ s|^grammars/||r);
