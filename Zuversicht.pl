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
        my $ret;
        for my $r (@r) {
            $ret .= $r->[0] =~ s/^'//r =~ s/'$//r ;
            $ret .= ' => (';
            $ret .= join ', ', $r->[1]->@*;
            $ret .= "),\n";
        };
        return $ret;
    }
    method Nonterminal(@values) {
        return "'$values[0]'";
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
        return if 'ε' eq $values[0];
        return q[T("'")] if q('\x27') eq $values[0];
        $values[0] =~ s/^'//;
        $values[0] =~ s/'$//;
        return 1 == length $values[0]
            ? "T('$values[0]')"
            : "r('$values[0]')";
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
        use v6;
        use Zuversicht;
        use JSON::Fast;
        sub T($token) { Terminal.new: :$token }
        sub N(Str $name) { Nonterminal.new: :$name }
        sub R(Pair $p) {
            return Rule.new(
                name => $p.key,
                sym => $p.value.map(-> $s {
                    given $s.^name {
                        when 'Str' { N($s) }
                        default { $s }
                    }
                }),
            );
        }
        sub r(Str $token) { Regular-Token.new: :$token }
        my @rules = Grammar::rules-from-ebnf((
        __GRAMMAR__
        ).map: { R $_ });
        my $grammar = Grammar.new(:@rules);
        my $parser = Parser.new(:$grammar);
        my $r = $parser.parse(:input($*IN.slurp));
        if $r.success {
            sub visit($v) {
                given $v {
                    when Nonterminal { $v.name, $v.tree.map({ visit $_ }).Slip }
                    when Terminal { $v.token }
                    when Any { Nil }
                }
            }
            print $r.results.map({ visit $_ }).map({ to-json($_) :!pretty }).join('␞');
        } else {
            say "parse error, predicted terminals at position { $r.position }: "
              ~ $r.predicted.map(*.key.token).join: ' ';
        }
        ...
    write_binary(
        "generated/${grammar_name}__Zuversicht.p6",
        $template =~ s/__GRAMMAR__/$generated/r
    );
    my @input = split /\n/, read_binary "input/$grammar_name";
    my @output = split /\n/, read_binary "output/$grammar_name";
    while (my ($idx, $input) = each @input) {
        $input =~ s/ //g; # FIXME I AM A DIRTY CHEATER
        my $status;
        my ($out, $err) = capture {
            open my $proc, '|-', 'perl6', "generated/${grammar_name}__Zuversicht.p6";
            $proc->print($input);
            close $proc;
            $status = $?;
        };
        cmp_set(
            [split '␞', $out],
            [split '␞', $output[$idx]],
            "${grammar_name}__Zuversicht.p6 $input"
        ) or diag $err;
    }
    done_testing;
}

die "usage: $0 grammar_name\n" unless $ARGV[0];
MAIN($ARGV[0] =~ s|^grammars/||r);
