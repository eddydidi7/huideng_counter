/// One body-content rule for Notes and Redbook posts.
///
/// Count Unicode code points so Chinese, English, emoji and line breaks use the
/// same rule on every editing path. Rich-text callers pass their plain text.
const maxArticleContentCharacters = 5000000;

int articleContentCharacterCount(String text) => text.runes.length;

bool isArticleContentWithinLimit(String text) =>
    articleContentCharacterCount(text) <= maxArticleContentCharacters;
