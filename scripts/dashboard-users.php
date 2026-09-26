<?php

/**
 * CLI to manage the dashboard user store.
 *
 * This file lives outside the DocumentRoot on purpose: it must never be
 * reachable over HTTP.
 *
 * Usage:
 *   php dashboard-users.php add <username> <viewer|operator|admin>
 *   php dashboard-users.php list
 *   php dashboard-users.php enable  <username>
 *   php dashboard-users.php disable <username>
 *   php dashboard-users.php passwd <username>
 *   php dashboard-users.php delete <username>
 *
 * Password input:
 *   Default is an interactive prompt with terminal echo disabled.
 *   For automation use --password-stdin and pipe the password in. There is
 *   deliberately no --password flag: command line arguments are visible to any
 *   local user through /proc and the shell history.
 *
 * The store path defaults to /etc/chae-dashboard/users.json and can be
 * overridden with --file <path> or the CHAE_USERS_FILE environment variable.
 */

declare(strict_types=1);

const ROLES = ['viewer' => 1, 'operator' => 2, 'admin' => 3];

exit(main($argv));

function main(array $argv): int
{
    $args = array_slice($argv, 1);
    $opts = extract_options($args);
    $file = $opts['file'] ?? (getenv('CHAE_USERS_FILE') ?: '/etc/chae-dashboard/users.json');

    $command = $args[0] ?? '';

    switch ($command) {
        case 'add':
            return cmd_add($file, $args[1] ?? '', $args[2] ?? '', $opts);
        case 'list':
            return cmd_list($file);
        case 'enable':
        case 'disable':
            return cmd_toggle($file, $args[1] ?? '', $command === 'enable');
        case 'passwd':
            return cmd_passwd($file, $args[1] ?? '', $opts);
        case 'delete':
            return cmd_delete($file, $args[1] ?? '');
        case 'help':
        case '--help':
        case '-h':
        case '':
            usage();
            return $command === '' ? 1 : 0;
        default:
            fwrite(STDERR, "Unknown command: {$command}\n\n");
            usage();
            return 1;
    }
}

/**
 * Splits --flag=value and --flag value pairs out of the argument list. Positional
 * arguments keep their original order. An empty string is kept as the value of
 * a value-taking flag so the caller can tell it apart from a boolean flag.
 */
function extract_options(array &$args): array
{
    $opts = [];
    $rest = [];

    $count = count($args);
    for ($i = 0; $i < $count; $i++) {
        $arg = $args[$i];

        if (!str_starts_with($arg, '--') || $arg === '--') {
            $rest[] = $arg;
            continue;
        }

        $arg = substr($arg, 2);

        if (str_contains($arg, '=')) {
            [$key, $value] = explode('=', $arg, 2);
            $opts[$key] = $value;
            continue;
        }

        $next = $args[$i + 1] ?? null;
        if ($next !== null && !str_starts_with($next, '--')) {
            $opts[$arg] = $next;
            $i++;
            continue;
        }

        $opts[$arg] = true;
    }

    $args = $rest;

    return $opts;
}

function usage(): void
{
    fwrite(STDOUT, <<<TXT
    dashboard-users.php - dashboard user store manager

      add <username> <role>    Create a user. Role: viewer|operator|admin
      list                     List usernames, roles and status
      enable  <username>        Re-enable a disabled user
      disable <username>        Disable a user without deleting it
      passwd <username>         Replace the password
      delete <username>         Remove a user

    Options:
      --file <path>             Store path (default /etc/chae-dashboard/users.json)
      --password-stdin          Read the password from stdin instead of prompting

    TXT);
}

function valid_username(string $username): bool
{
    return (bool) preg_match('/^[a-z0-9._-]{1,64}$/', $username);
}

function read_store(string $file): array
{
    if (!is_file($file)) {
        return ['users' => []];
    }

    $raw = file_get_contents($file);
    if ($raw === false) {
        fail("Cannot read store: {$file}\n");
    }

    $data = json_decode($raw, true);
    if (!is_array($data) || !isset($data['users']) || !is_array($data['users'])) {
        fail("Store is not valid JSON with a 'users' array: {$file}\n");
    }

    return $data;
}

function find(array $store, string $username): int
{
    foreach ($store['users'] as $i => $user) {
        if (($user['username'] ?? null) === $username) {
            return $i;
        }
    }

    return -1;
}

/**
 * Writes tmp + rename so a reader never observes a half written file, and
 * restricts the file to owner rw plus group r so only root and the web group
 * can read the hashes.
 */
function write_store(string $file, array $store): void
{
    $json = json_encode($store, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
    if ($json === false) {
        fail("Failed to encode the store.\n");
    }

    $dir = dirname($file);
    if (!is_dir($dir) || !is_writable($dir)) {
        fail("Store directory is missing or not writable by this user: {$dir}\n"
            . "Create it and set ownership so the web server can read it, for example:\n"
            . "  sudo install -d -o root -g www-data -m 0750 {$dir}\n");
    }

    $tmp = $file . '.' . getmypid() . '.tmp';
    if (file_put_contents($tmp, $json . "\n", LOCK_EX) === false) {
        fail("Cannot write temporary file: {$tmp}\n");
    }

    if (!chmod($tmp, 0640)) {
        @unlink($tmp);
        fail("Cannot set permissions on the temporary file.\n");
    }

    if (!rename($tmp, $file)) {
        @unlink($tmp);
        fail("Cannot move the temporary file into place: {$file}\n");
    }
}

/**
 * Reads a password without echoing it. Returns the raw value; it is hashed
 * immediately by the caller and never stored or printed.
 */
function read_password(array $opts): string
{
    if (isset($opts['password-stdin'])) {
        $pw = trim((string) fgets(STDIN));
    } else {
        $pw = hidden_prompt('Password: ');
        if ($pw === '') {
            $confirm = hidden_prompt('Confirm password: ');
            if ($pw !== $confirm) {
                fail("Passwords do not match.\n");
            }
        }
    }

    if (strlen($pw) < 8) {
        fail("Password must be at least 8 characters long.\n");
    }

    return $pw;
}

function hidden_prompt(string $label): string
{
    $tty = @fopen('/dev/tty', 'r+');
    if ($tty === false) {
        fwrite(STDOUT, $label);
        $line = trim((string) fgets(STDIN));
        fwrite(STDOUT, "\n");

        return $line;
    }

    fwrite($tty, $label);
    @shell_exec('stty -echo 2>/dev/null');
    $line = trim((string) fgets($tty));
    @shell_exec('stty echo 2>/dev/null');
    fwrite($tty, "\n");
    fclose($tty);

    return $line;
}

function cmd_add(string $file, string $username, string $role, array $opts): int
{
    if (!valid_username($username)) {
        fail("Invalid username. Use lowercase letters, digits, dot, dash or underscore (max 64).\n");
    }

    if (!isset(ROLES[$role])) {
        fail("Invalid role. Use one of: " . implode(', ', array_keys(ROLES)) . "\n");
    }

    $store = read_store($file);
    if (find($store, $username) !== -1) {
        fail("User already exists: {$username}\n");
    }

    $password = read_password($opts);

    $store['users'][] = [
        'username'      => $username,
        'password_hash' => password_hash($password, PASSWORD_ARGON2ID),
        'role'          => $role,
        'created_at'    => date('c'),
        'disabled'      => false,
    ];

    // The variable holding the clear text password is dropped as early as
    // possible; nothing in this process ever prints or logs it.
    unset($password);

    write_store($file, $store);
    fwrite(STDOUT, "Created user {$username} with role {$role}\n");

    return 0;
}

function cmd_list(string $file): int
{
    $store = read_store($file);

    if ($store['users'] === []) {
        fwrite(STDOUT, "No users.\n");

        return 0;
    }

    // The password hash is never part of the output.
    fwrite(STDOUT, sprintf("%-24s %-10s %-26s %s\n", 'USERNAME', 'ROLE', 'CREATED_AT', 'STATUS'));
    foreach ($store['users'] as $user) {
        fwrite(STDOUT, sprintf(
            "%-24s %-10s %-26s %s\n",
            (string) ($user['username'] ?? '?'),
            (string) ($user['role'] ?? '?'),
            (string) ($user['created_at'] ?? '?'),
            !empty($user['disabled']) ? 'disabled' : 'active'
        ));
    }

    return 0;
}

function cmd_toggle(string $file, string $username, bool $enabled): int
{
    $store = read_store($file);
    $index = find($store, $username);

    if ($index === -1) {
        fail("Unknown user: {$username}\n");
    }

    $store['users'][$index]['disabled'] = !$enabled;
    write_store($file, $store);
    fwrite(STDOUT, ($enabled ? 'Enabled ' : 'Disabled ') . "{$username}\n");

    return 0;
}

function cmd_passwd(string $file, string $username, array $opts): int
{
    $store = read_store($file);
    $index = find($store, $username);

    if ($index === -1) {
        fail("Unknown user: {$username}\n");
    }

    $password = read_password($opts);
    $store['users'][$index]['password_hash'] = password_hash($password, PASSWORD_ARGON2ID);
    $store['users'][$index]['password_changed_at'] = date('c');
    unset($password);

    write_store($file, $store);
    fwrite(STDOUT, "Password updated for {$username}\n");

    return 0;
}

function cmd_delete(string $file, string $username): int
{
    $store = read_store($file);
    $index = find($store, $username);

    if ($index === -1) {
        fail("Unknown user: {$username}\n");
    }

    array_splice($store['users'], $index, 1);
    write_store($file, $store);
    fwrite(STDOUT, "Deleted user {$username}\n");

    return 0;
}

function fail(string $message): never
{
    fwrite(STDERR, $message);
    exit(1);
}
