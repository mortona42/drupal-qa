<?php

/**
 * @file
 * Rewrites core's phpunit.xml.dist into a runnable config outside core.
 *
 * Drupal's shipped configuration is written to be used from within core/: its
 * bootstrap, cache directory and test suite paths are all relative to the file's
 * own location. Drupal core's CI copies it to core/phpunit.xml and edits it in
 * place; doing that here would write into the user's checkout, so instead the
 * paths are made absolute and the result is written to the cache directory.
 *
 * Two other adjustments match what the GitLab templates do:
 *  - Coverage <source>/<coverage> sections are dropped unless coverage was
 *    asked for. They make every run slower and are meaningless without a driver.
 *  - Deprecation details are hidden by default. A contrib run reports dozens of
 *    deprecations triggered by core itself, which buries the test results;
 *    `--deprecations=show` brings them back.
 *
 * Usage:
 *   php prepare-phpunit-xml.php <source.xml> <core-dir> <out.xml> [options]
 * Options:
 *   --coverage       Keep the coverage configuration.
 *   --deprecations   Keep deprecation detail output.
 */

declare(strict_types=1);

[$self, $source, $coreDir, $out] = array_pad(array_slice($argv, 0, 4), 4, NULL);
if ($source === NULL || $coreDir === NULL || $out === NULL) {
  fwrite(STDERR, "usage: {$argv[0]} <source.xml> <core-dir> <out.xml> [--coverage] [--deprecations]\n");
  exit(2);
}
$flags = array_slice($argv, 4);
$keepCoverage = in_array('--coverage', $flags, TRUE);
$keepDeprecations = in_array('--deprecations', $flags, TRUE);

if (!is_readable($source)) {
  fwrite(STDERR, "cannot read $source\n");
  exit(1);
}

$coreDir = rtrim((string) realpath($coreDir), '/');

$xml = new DOMDocument();
$xml->preserveWhiteSpace = FALSE;
$xml->formatOutput = TRUE;
if (!$xml->load($source)) {
  fwrite(STDERR, "cannot parse $source\n");
  exit(1);
}
$root = $xml->documentElement;

/**
 * Resolves a path that was written relative to core/ into an absolute one.
 */
$absolute = static function (string $path) use ($coreDir): string {
  if ($path === '' || $path[0] === '/' || preg_match('#^[a-z]+://#i', $path)) {
    return $path;
  }
  $relative = preg_replace('#^\./#', '', $path);
  return $relative === '' ? $coreDir : $coreDir . '/' . $relative;
};

foreach (['bootstrap', 'cacheDirectory'] as $attribute) {
  if ($root->hasAttribute($attribute)) {
    $root->setAttribute($attribute, $absolute($root->getAttribute($attribute)));
  }
}

foreach (['directory', 'file', 'exclude'] as $tag) {
  foreach (iterator_to_array($root->getElementsByTagName($tag)) as $node) {
    $value = trim($node->textContent);
    if ($value !== '') {
      $node->textContent = $absolute($value);
    }
  }
}

if (!$keepCoverage) {
  foreach (['coverage', 'source'] as $tag) {
    $nodes = $root->getElementsByTagName($tag);
    while ($nodes->length > 0) {
      $nodes->item(0)->parentNode->removeChild($nodes->item(0));
    }
  }
}

if (!$keepDeprecations) {
  foreach ([
    'displayDetailsOnTestsThatTriggerDeprecations',
    'displayDetailsOnPhpunitDeprecations',
  ] as $attribute) {
    $root->setAttribute($attribute, 'false');
  }
}

// The runner supplies these through the environment, where they can carry a
// password without ending up in a file. An empty value here would win over the
// environment, so remove them.
foreach (iterator_to_array($root->getElementsByTagName('env')) as $node) {
  if ($node->getAttribute('value') === '') {
    $node->parentNode->removeChild($node);
  }
}

if ($xml->save($out) === FALSE) {
  fwrite(STDERR, "cannot write $out\n");
  exit(1);
}
