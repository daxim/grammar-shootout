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
        our $ID = 'id0';
        my @r = map {
            ref($_)
                ? Metagrammar->can($_->{type})->($_->{type}, $_->{values}->@*)
                : $_
        } @values;
        my $start = $r[0][0]->$*;
        tie my %r, 'Tie::Hash::Indexed';
        for my $r (@r) {
            my $name = $r->[0]->$*;
            push $r{$name}->@*, $r->[1];
        }
        my $ret;
        for my $k (keys %r) {
            $ret .= "$k = ";
            my @syms;
            for my $syms ($r{$k}->@*) {
                my @monikers;
                my $p = join ' ', map {
                    if ($_->isa('Nonterminal')) {
                        $ID++;
                        push @monikers, $ID;
                        "$ID:" . $_->$*
                    } elsif ($_->isa('Terminal')) {
                        my $t = $_->$*;
                        $t =~ s/\\x/\\\\x/g;
                        $ID++;
                        push @monikers, '' eq $t ? 'null' : $ID;
                        "_ $ID:'$t' _"
                    } else {
                        die;
                    }
                } $syms->@*;
                $p .= "\t{ return ['$k', " . join(',', @monikers) . "] }";
                push @syms, $p;
            }
            $ret .= join " / ", @syms;
            $ret .= "\n";
        };
        return($ret, $start);
    }
    method Nonterminal(@values) {
        return bless \$values[0], 'Nonterminal';
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
        my $r = [map {
            ref($_)
                ? Metagrammar->can($_->{type})->($_->{type}, $_->{values}->@*)
                : $_
        } @values]->[0];
    }
    method Symplus(@values) {
        my $r = [map {
            ref($_)
                ? Metagrammar->can($_->{type})->($_->{type}, $_->{values}->@*)
                : $_
        } @values];
    }
    method Terminal(@values) {
        $values[0] = '' if 'ε' eq $values[0];
        $values[0] =~ s/^'//;
        $values[0] =~ s/'$//;
        $values[0] =~ s/\\x([0-9]+)/chr hex $1/eg;
        $values[0] =~ s|/|\\x2f|g;
        $values[0] =~ s|'|\\x27|g;
        return bless \$values[0], 'Terminal';
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
    my ($generated, $start) = Metagrammar->can($v->{type})->($v->{type}, $v->{values}->@*);
    mkdir 'generated';
    my $template = <<~'...';
        (async function() {
            const get_stdin = require('get-stdin');
            const peg = require('pegjs');
            const parser = peg.generate(`
        _ = [ ]*
        __GRAMMAR__
            `, { allowedStartRules: ['__START__'] });
            process.stdout.write(JSON.stringify(
                parser.parse(await get_stdin())
                ));
        })();
        ...

    write_binary(
        "generated/${grammar_name}__Pegjs.js",
        $template =~ s/__GRAMMAR__/$generated/r
                  =~ s/__START__/$start/r
    );
    my @input = split /\n/, read_binary "input/$grammar_name";
    my @output = split /\n/, read_binary "output/$grammar_name";
    while (my ($idx, $input) = each @input) {
        my $status;
        my ($out, $err) = capture {
            open my $proc, '|-', 'node', "generated/${grammar_name}__Pegjs.js";
            $proc->print($input);
            close $proc;
            $status = $?;
        };
        cmp_set(
            [split '␞', $out],
            [split '␞', $output[$idx]],
            "${grammar_name}__Pegjs.js $input"
        ) or diag $err;
    }
    done_testing;
}

die "usage: $0 grammar_name\n" unless $ARGV[0];
MAIN($ARGV[0] =~ s|^grammars/||r);
