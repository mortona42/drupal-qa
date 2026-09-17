<?php

/**
 * @file
 * Fallback Twig CS Fixer configuration, used when neither the project nor the
 * detected Drupal core provides one.
 *
 * Mirrors core/.twig-cs-fixer.php (Drupal 11.5+), but degrades gracefully: core's
 * version hard-requires Drupal\Core\Template\TwigTransTokenParser, which is only
 * loadable when a Drupal autoloader is present. Here the token parser is added
 * only when the class is actually available, so `drupal-qa twig` still works on a
 * standalone module checkout with no Drupal root at all.
 *
 * @see https://github.com/VincentLanglet/Twig-CS-Fixer/blob/main/docs/configuration.md
 */

use TwigCsFixer\Config\Config;
use TwigCsFixer\File\Finder;
use TwigCsFixer\Rules\Literal\CompactHashRule;
use TwigCsFixer\Rules\Whitespace\IndentRule;
use TwigCsFixer\Ruleset\Ruleset;
use TwigCsFixer\Standard\TwigCsFixer;

$config = new Config();

$cacheFile = getenv('DRUPAL_QA_TWIG_CACHE');
$config->setCacheFile($cacheFile !== FALSE && $cacheFile !== '' ? $cacheFile : NULL);

// {% trans %} is a Drupal extension to Twig. Without the token parser every
// translated template reports a syntax error, so register it whenever Drupal is
// on the autoloader.
if (class_exists('Drupal\Core\Template\TwigTransTokenParser')) {
  $config->addTokenParser(new \Drupal\Core\Template\TwigTransTokenParser());
}

$finder = new Finder();
$finder->exclude(['tests', 'vendor', 'node_modules']);
$config->setFinder($finder);

$ruleset = new Ruleset();
$ruleset->addStandard(new TwigCsFixer());

// Drupal's deviations from the upstream Twig standard.
$ruleset->overrideRule(new CompactHashRule(TRUE));
$ruleset->overrideRule(new IndentRule(spaceRatio: 2));

$config->allowNonFixableRules();
$config->setRuleset($ruleset);

return $config;
