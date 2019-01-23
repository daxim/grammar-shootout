#!/usr/bin/env perl
use 5.024;
use Capture::Tiny qw(capture);
use File::Slurper qw(read_binary write_binary);
use Marpa::R2 qw();
use Moops;
use Kavorka qw(fun);
use Test::More import => [qw(diag done_testing)];
use Test::Deep qw(cmp_set);

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
    method Equal(@values) {
        return $values[0] eq '⩴' ? '::=' : '~';
    }
    method Grammar(@values) {
        my $r = join '', map {
            ref($_)
                ? Metagrammar->can($_->{type})->($_->{type}, $_->{values}->@*)
                : $_
        } @values;
        return $r;
    }
    method Nonterminal(@values) {
        return shift @values;
    }
    method Rule(@values) {
        my $r = join ' ', map {
            ref($_)
                ? Metagrammar->can($_->{type})->($_->{type}, $_->{values}->@*)
                : $_
        } @values;
        return "$r\n";
    }
    method Sym(@values) {
        my $r = join '', map {
            ref($_)
                ? Metagrammar->can($_->{type})->($_->{type}, $_->{values}->@*)
                : $_
        } @values;
        return $r;
    }
    method Symplus(@values) {
        my $r = join ' ', map {
            ref($_)
                ? Metagrammar->can($_->{type})->($_->{type}, $_->{values}->@*)
                : $_
        } @values;
        return $r;
    }
    method Terminal(@values) {
        return '' if 'ε' eq $values[0];
        return '[\x27]' if q('\x27') eq $values[0];
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
        use JSON::MaybeXS qw(encode_json);
        use Marpa::R2 qw();
        my $grammar = Marpa::R2::Scanless::G->new({source => \<<'',
        :default ::= action => [name, values]
        lexeme default = action => [name, values] latm => 1
        :discard ~ whitespace
        whitespace ~ [\s]+
        __GRAMMAR__
        });
        my $r = Marpa::R2::Scanless::R->new({grammar => $grammar});
        $r->read(\(do { local $/; readline; } // ''));
        my @v;
        while (my $v = $r->value) {
            push @v, $v->$*;
        }
        print join '␞', map { encode_json $_ } @v;
        ...

    write_binary(
        "generated/${grammar_name}__Marpa-R2.pl",
        $template =~ s/__GRAMMAR__/$generated/r
    );
    my @input = split /\n/, read_binary "input/$grammar_name";
    my @output = split /\n/, read_binary "output/$grammar_name";
    while (my ($idx, $input) = each @input) {
        my $status;
        my ($out, $err) = capture {
            open my $proc, '|-', $^X, "generated/${grammar_name}__Marpa-R2.pl";
            $proc->print($input);
            close $proc;
            $status = $?;
        };
        cmp_set(
            [split '␞', $out],
            [split '␞', $output[$idx]],
            "${grammar_name}__Marpa-R2.pl $input"
        ) or diag $err;
    }
    done_testing;
}

die "usage: $0 grammar_name\n" unless $ARGV[0];
MAIN($ARGV[0] =~ s|^grammars/||r);
