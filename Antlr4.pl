#!/usr/bin/env perl
use 5.024;
use Capture::Tiny qw(capture);
use File::Slurper qw(read_binary write_binary);
use Marpa::R2 qw();
use Moops;
use Kavorka qw(fun);
use Test::More import => [qw(diag fail done_testing)];
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
        my $start = $r[0][0]->$*;
        tie my %r, 'Tie::Hash::Indexed';
        for my $r (@r) {
            my $name = $r->[0]->$*;
            push $r{$name}->@*, $r->[1];
        }
        my $ret;
        for my $k (keys %r) {
            $ret .= "rule$k : ";
            my @syms;
            for my $syms ($r{$k}->@*) {
                my $p = join ' ', map {
                    if ('' eq $_) {
                        ''
                    } elsif (q('\\u0027') eq $_) {
                        q('\\u0027')
                    } elsif ($_->isa('Nonterminal')) {
                        sprintf 'rule%s', $_->$*
                    } elsif ($_->isa('Terminal')) {
                        $_->$*
                    } else {
                        die;
                    }
                } $syms->@*;
                push @syms, $p;
            }
            $ret .= join ' | ', @syms;
            $ret .= " ;\n";
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
        return '' if 'ε' eq $values[0];
        return q('\u0027') if q('\x27') eq $values[0];
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
    my $munged_name = $grammar_name =~ s/-/_/gr;
    my $v = visit(Metagrammar->new->parse(input => $grammar));
    my ($generated, $start) = Metagrammar->can($v->{type})->($v->{type}, $v->{values}->@*);
    mkdir 'generated';
    chdir 'generated';
    write_binary("${munged_name}__Antlr4.g4", <<~"__GRAMMAR__");
        grammar ${munged_name}__Antlr4;
        WS : [ \\t\\r\\n]+ -> skip ;
        $generated
        __GRAMMAR__

    system qw(java -Xmx500M org.antlr.v4.Tool -Dlanguage=JavaScript),
        "${munged_name}__Antlr4.g4"
        and do {
            fail "compile ${munged_name}__Antlr4.g4";
            done_testing;
            exit;
        };
    write_binary("${munged_name}__Antlr4.js", <<~"...");
        'use strict';
        function visit(rule_context) {
            return rule_context.children
                ? rule_context.children.map(child => {
                    if (Object.getPrototypeOf(child).constructor.toString().match(
                        /^function TerminalNodeImpl/
                    )) {
                        let token = child.symbol;
                        return token.source[1].strdata.slice(token.start, token.stop + 1);
                    } else {
                        return [
                            child.parser.ruleNames[child.ruleIndex].replace(/^rule/, ''),
                            ...visit(child)
                        ];
                    }
                })
                : [null];
        };
        (async function() {
            const get_stdin = require('get-stdin');
            const antlr4 = require('antlr4');
            const ${munged_name}__Antlr4Lexer = require('./${munged_name}__Antlr4Lexer').${munged_name}__Antlr4Lexer;
            const ${munged_name}__Antlr4Parser = require('./${munged_name}__Antlr4Parser').${munged_name}__Antlr4Parser;
            const chars = new antlr4.InputStream(await get_stdin());
            const lexer = new ${munged_name}__Antlr4Lexer(chars);
            const tokens = new antlr4.CommonTokenStream(lexer);
            const parser = new ${munged_name}__Antlr4Parser(tokens);
            parser.buildParseTrees = true;
            const tree = parser.rule$start();
            process.stdout.write(
                tree.exception
                    ? tree.exception.toString()
                    : JSON.stringify(['$start', ...visit(tree)])
            );
        })();
        ...

    my @input = split /\n/, read_binary "../input/$grammar_name";
    my @output = split /\n/, read_binary "../output/$grammar_name";
    while (my ($idx, $input) = each @input) {
        my $status;
        my ($out, $err) = capture {
            open my $proc, '|-', 'node', "${munged_name}__Antlr4.js";
            $proc->print($input);
            close $proc;
            $status = $?;
        };
        cmp_set(
            [split '␞', $out],
            [split '␞', $output[$idx]],
            "${grammar_name}__Antlr4.js $input"
        ) or diag $err;
    }
    done_testing;
}

die "usage: $0 grammar_name\n" unless $ARGV[0];
MAIN($ARGV[0] =~ s|^grammars/||r);
