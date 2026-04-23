use ra_ap_syntax::SyntaxKind;

#[derive(Debug, Clone, Copy, Eq, PartialEq, Hash)]
pub enum TokenRole {
    Delimiter,
    Identifier,
    Keyword,
    Comment,
    StringLiteral,
    Type,
    TriviaLike,
    Number,
    Operator,
    Other,
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct DisplayToken {
    pub text: String,
    pub role: TokenRole,
}

pub fn classify_token(kind: SyntaxKind, text: &str) -> TokenRole {
    use ra_ap_syntax::SyntaxKind::*;

    match kind {
        COMMENT => TokenRole::Comment,
        STRING | BYTE_STRING | C_STRING => TokenRole::StringLiteral,
        CHAR => TokenRole::StringLiteral,
        IDENT => {
            if text.chars().next().is_some_and(char::is_uppercase) {
                TokenRole::Type
            } else {
                TokenRole::Identifier
            }
        }
        INT_NUMBER | FLOAT_NUMBER => TokenRole::Number,
        WHITESPACE => TokenRole::TriviaLike,
        L_CURLY | R_CURLY | L_PAREN | R_PAREN | L_BRACK | R_BRACK => TokenRole::Delimiter,
        FN_KW | PUB_KW | STRUCT_KW | ENUM_KW | IMPL_KW | TRAIT_KW | MOD_KW | CONST_KW | LET_KW
        | MATCH_KW | IF_KW | ELSE_KW | RETURN_KW | USE_KW => TokenRole::Keyword,
        THIN_ARROW | EQ | FAT_ARROW | COLON | COLON2 | COMMA | DOT | SEMICOLON | PLUS | MINUS
        | STAR | SLASH | PERCENT | AMP | PIPE | BANG => TokenRole::Operator,
        _ => TokenRole::Other,
    }
}
