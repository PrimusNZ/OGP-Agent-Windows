#!/usr/bin/perl
#
# OGP - Open Game Panel
# Copyright (C) 2008 - 2014 The OGP Development Team
#
# http://www.opengamepanel.org/
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.
#

use warnings;
use strict;

use Cwd;			 # Fast way to get the current directory
use lib getcwd();
use Frontier::Daemon::Forking;	# Forking XML-RPC server
use File::Copy;				   # Simple file copy functions
use File::Copy::Recursive
  qw(fcopy rcopy dircopy fmove rmove dirmove pathempty pathrmdir)
  ;							   # Used to copy whole directories
use File::Basename; # Used to get the file name or the directory name from a given path
use Crypt::XXTEA;	# Encryption between webpages and agent.
use Cfg::Config;	 # Config file
use Cfg::Preferences;   # Preferences file
use Fcntl ':flock';  # Import LOCK_* constants for file locking
use LWP::UserAgent; # Used for fetching URLs
use MIME::Base64;	# Used to ensure data travelling right through the network.
use Getopt::Long;	# Used for command line params.
use Path::Class::File;	# Used to handle files and directories.
use File::Path qw(mkpath);
use Archive::Extract;	 # Used to handle archived files.
use File::Find;
use Schedule::Cron; # Used for scheduling tasks

# Compression tools
use IO::Compress::Bzip2 qw(bzip2 $Bzip2Error); # Used to compress files to bz2.
use Compress::Zlib; # Used to compress file download buffers to zlib.
use Archive::Tar; # Used to create tar, tgz or tbz archives.
use Archive::Zip qw( :ERROR_CODES :CONSTANTS ); # Used to create zip archives.

# Current location of the agent.
use constant AGENT_RUN_DIR => getcwd();

# Load our config file values
use constant AGENT_KEY	  => $Cfg::Config{key};
use constant AGENT_IP	   => $Cfg::Config{listen_ip};
use constant AGENT_LOG_FILE => $Cfg::Config{logfile};
use constant AGENT_PORT	 => $Cfg::Config{listen_port};
use constant AGENT_VERSION  => $Cfg::Config{version};
use constant SCREEN_LOG_LOCAL  => $Cfg::Preferences{screen_log_local};
use constant DELETE_LOGS_AFTER  => $Cfg::Preferences{delete_logs_after};
use constant AGENT_PID_FILE =>
  Path::Class::File->new(AGENT_RUN_DIR, 'ogp_agent.pid');
use constant STEAM_LICENSE_OK => "Accept";
use constant STEAM_LICENSE	=> $Cfg::Config{steam_license};
use constant MANUAL_TMP_DIR   => Path::Class::Dir->new(AGENT_RUN_DIR, 'tmp');
use constant STEAMCMD_CLIENT_DIR => Path::Class::Dir->new(AGENT_RUN_DIR, 'steamcmd');
use constant STEAMCMD_CLIENT_BIN =>
  Path::Class::File->new(STEAMCMD_CLIENT_DIR, 'steamcmd.exe');
use constant SCREEN_LOGS_DIR =>
  Path::Class::Dir->new(AGENT_RUN_DIR, 'screenlogs');
use constant GAME_STARTUP_DIR =>
  Path::Class::Dir->new(AGENT_RUN_DIR, 'startups');
use constant SCREENRC_FILE =>
  Path::Class::File->new(AGENT_RUN_DIR, 'ogp_screenrc');
use constant SCREEN_TYPE_HOME   => "HOME";
use constant SCREEN_TYPE_UPDATE => "UPDATE";
use constant FD_DIR => Path::Class::Dir->new(AGENT_RUN_DIR, 'FastDownload');
use constant FD_ALIASES_DIR => Path::Class::Dir->new(FD_DIR, 'aliases');
use constant FD_PID_FILE => Path::Class::File->new(FD_DIR, 'fd.pid');
use constant SCHED_PID => Path::Class::File->new(AGENT_RUN_DIR, 'scheduler.pid');
use constant SCHED_TASKS => Path::Class::File->new(AGENT_RUN_DIR, 'scheduler.tasks');
use constant SCHED_LOG_FILE => Path::Class::File->new(AGENT_RUN_DIR, 'scheduler.log');

my $no_startups	= 0;
my $clear_startups = 0;
our $log_std_out = 0;

GetOptions(
		   'no-startups'	=> \$no_startups,
		   'clear-startups' => \$clear_startups,
		   'log-stdout'	 => \$log_std_out
		  );

# Starting the agent as root user is not supported anymore.
if ($< == 0)
{
	print "ERROR: You are trying to start the agent as root user.";
	print "This is not currently supported. If you wish to start the";
	print "you need to create a normal user account for it.";
	exit 1;
}

### Logger function.
### @param line the line that is put to the log file.
sub logger
{
	my $logcmd	 = $_[0];
	my $also_print = 0;

	if (@_ == 2)
	{
		($also_print) = $_[1];
	}

	$logcmd = localtime() . " $logcmd\n";

	if ($log_std_out == 1)
	{
		print "$logcmd";
		return;
	}
	if ($also_print == 1)
	{
		print "$logcmd";
	}

	open(LOGFILE, '>>', AGENT_LOG_FILE)
	  or die("Can't open " . AGENT_LOG_FILE . " - $!");
	flock(LOGFILE, LOCK_EX) or die("Failed to lock log file.");
	seek(LOGFILE, 0, 2) or die("Failed to seek to end of file.");
	print LOGFILE "$logcmd" or die("Failed to write to log file.");
	flock(LOGFILE, LOCK_UN) or die("Failed to unlock log file.");
	close(LOGFILE) or die("Failed to close log file.");
}

# Check the screen logs folder
if (!-d SCREEN_LOGS_DIR && !mkdir SCREEN_LOGS_DIR)
{
	logger "Could not create " . SCREEN_LOGS_DIR . " directory $!.", 1;
	exit -1;
}

# Rotate the log file
if (-e AGENT_LOG_FILE)
{
	if (-e AGENT_LOG_FILE . ".bak")
	{
		unlink(AGENT_LOG_FILE . ".bak");
	}
	logger "Rotating log file";
	move(AGENT_LOG_FILE, AGENT_LOG_FILE . ".bak");
	logger "New log file created";
}

if (check_steam_cmd_client() == -1)
{
	print "ERROR: You must download and uncompress the new steamcmd package.";
	print "ENSURE TO INSTALL IT IN /OGP/steamcmd directory,";
	print "so it can be managed by the agent to install servers.";
	exit 1;
}

# create the directory for startup flags
if (!-e GAME_STARTUP_DIR)
{
	logger "Creating the startups directory " . GAME_STARTUP_DIR . "";
	if (!mkdir GAME_STARTUP_DIR)
	{
		my $message =
			"Failed to create the "
		  . GAME_STARTUP_DIR
		  . " directory - check permissions. Errno: $!";
		logger $message, 1;
		exit 1;
	}
}
elsif ($clear_startups)
{
	opendir(STARTUPDIR, GAME_STARTUP_DIR);
	while (my $startup_file = readdir(STARTUPDIR))
	{

		# Skip . and ..
		next if $startup_file =~ /^\./;
		$startup_file = Path::Class::File->new(GAME_STARTUP_DIR, $startup_file);
		logger "Removing " . $startup_file . ".";
		unlink($startup_file);
	}
	closedir(STARTUPDIR);
}
# If the directory already existed check if we need to start some games.
elsif ($no_startups != 1)
{
	system('screen -wipe > /dev/null 2>&1');
	# Loop through all the startup flags, and call universal startup
	opendir(STARTUPDIR, GAME_STARTUP_DIR);
	logger "Reading startup flags from " . GAME_STARTUP_DIR . "";
	while (my $dirlist = readdir(STARTUPDIR))
	{

		# Skip . and ..
		next if $dirlist =~ /^\./;
		logger "Found $dirlist";
		open(STARTFILE, '<', Path::Class::Dir->new(GAME_STARTUP_DIR, $dirlist))
		  || logger "Error opening start flag $!";
		while (<STARTFILE>)
		{
			my (
				$home_id,   $home_path,   $server_exe,
				$run_dir,   $startup_cmd, $server_port,
				$server_ip, $cpu,		 $nice
			   ) = split(',', $_);
			
			if (is_screen_running_without_decrypt(SCREEN_TYPE_HOME, $home_id) ==
				1)
			{
				logger
				  "This server ($server_exe on $server_ip : $server_port) is already running (ID: $home_id).";
				next;
			}

			logger "Starting server_exe $server_exe from home $home_path.";
			universal_start_without_decrypt(
										 $home_id,   $home_path,   $server_exe,
										 $run_dir,   $startup_cmd, $server_port,
										 $server_ip, $cpu,		 $nice
										   );
		}
		close(STARTFILE);
	}
	closedir(STARTUPDIR);
}

# Create the pid file
open(PID, '>', AGENT_PID_FILE)
  or die("Can't write to pid file - " . AGENT_PID_FILE . "\n");
print PID "$$\n";
close(PID);

logger "Open Game Panel - Agent started - "
  . AGENT_VERSION
  . " - port "
  . AGENT_PORT
  . " - PID $$", 1;

# Stop previous scheduler process if exists
scheduler_stop();	
# Create new object with default dispatcher for scheduled tasks
my $cron = new Schedule::Cron( \&scheduler_dispatcher, {
                                        nofork => 1,
                                        loglevel => 0,
                                        log => sub { print $_[1], "\n"; }
                                       } );

$cron->add_entry( "* * * * * *", \&scheduler_read_tasks );
# Run scheduler
$cron->run( {detach=>1, pid_file=>SCHED_PID} );

if(-e Path::Class::File->new(FD_DIR, 'Settings.pm'))
{
	require "FastDownload/Settings.pm"; # Settings for Fast Download Daemon.
	if(defined($FastDownload::Settings{autostart_on_agent_startup}) && $FastDownload::Settings{autostart_on_agent_startup} eq "1")
	{
		start_fastdl();
	}
}

my $d = Frontier::Daemon::Forking->new(
			 methods => {
				 is_screen_running				=> \&is_screen_running,
				 universal_start				=> \&universal_start, 
				 cpu_count						=> \&cpu_count,
				 rfile_exists					=> \&rfile_exists,
				 quick_chk						=> \&quick_chk,
				 steam_cmd						=> \&steam_cmd,
				 get_log						=> \&get_log,
				 stop_server					=> \&stop_server,
				 send_rcon_command				=> \&send_rcon_command,
				 dirlist						=> \&dirlist,
				 dirlistfm						=> \&dirlistfm,
				 readfile						=> \&readfile,
				 writefile						=> \&writefile,
				 rebootnow						=> \&rebootnow,
				 what_os						=> \&what_os,
				 start_file_download			=> \&start_file_download,
				 is_file_download_in_progress	=> \&is_file_download_in_progress,
				 uncompress_file				=> \&uncompress_file,
				 discover_ips					=> \&discover_ips,
				 mon_stats						=> \&mon_stats,
				 exec							=> \&exec,
				 clone_home						=> \&clone_home,
				 remove_home					=> \&remove_home,
				 start_rsync_install			=> \&start_rsync_install,
				 rsync_progress					=> \&rsync_progress,
				 restart_server					=> \&restart_server,
				 sudo_exec						=> \&sudo_exec,
				 master_server_update			=> \&master_server_update,
				 secure_path					=> \&secure_path,
				 get_chattr						=> \&get_chattr,
				 ftp_mgr						=> \&ftp_mgr,
				 compress_files					=> \&compress_files,
				 stop_fastdl					=> \&stop_fastdl,
				 restart_fastdl					=> \&restart_fastdl,
				 fastdl_status					=> \&fastdl_status,
				 fastdl_get_aliases				=> \&fastdl_get_aliases,
				 fastdl_add_alias				=> \&fastdl_add_alias,
				 fastdl_del_alias				=> \&fastdl_del_alias,
				 fastdl_get_info				=> \&fastdl_get_info,
				 fastdl_create_config			=> \&fastdl_create_config,
				 agent_restart					=> \&agent_restart,
				 scheduler_add_task				=> \&scheduler_add_task,
				 scheduler_del_task				=> \&scheduler_del_task,
				 scheduler_list_tasks			=> \&scheduler_list_tasks,
				 scheduler_edit_task			=> \&scheduler_edit_task,
				 get_file_part					=> \&get_file_part,
				 stop_update					=> \&stop_update,
				 shell_action					=> \&shell_action,
				 remote_query					=> \&remote_query
			 },
			 debug	 => 4,
			 LocalPort => AGENT_PORT,
			 LocalAddr => AGENT_IP,
			 ReuseAddr => '1'
) or die "Couldn't start OGP Agent: $!";

sub backup_home_log
{
	my ($home_id, $log_file) = @_;
	
	my $home_backup_dir = SCREEN_LOGS_DIR . "/home_id_" . $home_id;
		
	if( ! -e $home_backup_dir )
	{
		if( ! mkdir $home_backup_dir )
		{
			logger "Can not create a backup directory at $home_backup_dir.";
			return 1;
		}
	}
	
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
	
	my $backup_file_name =  $mday . $mon . $year . '_' . $hour . 'h' . $min . 'm' . $sec . "s.log";
	
	my $output_path = $home_backup_dir . "/" . $backup_file_name;
	
	# Used for deleting log files older than DELETE_LOGS_AFTER
	my @file_list;
	my @find_dirs; # directories to search
	my $now = time(); # get current time
	my $days;
	if((DELETE_LOGS_AFTER =~ /^[+-]?\d+$/) && (DELETE_LOGS_AFTER > 0)){
		$days = DELETE_LOGS_AFTER; # how many days old
	}else{
		$days = 30; # how many days old
	}
	my $seconds_per_day = 60*60*24; # seconds in a day
	my $AGE = $days*$seconds_per_day; # age in seconds
	push (@find_dirs, $home_backup_dir);
	
	# Create local copy of log file backup in the log_backups folder and current user home directory if SCREEN_LOG_LOCAL = 1 
	if(SCREEN_LOG_LOCAL == 1)
	{
		# Create local backups folder
		my $local_log_folder = Path::Class::Dir->new("logs_backup");
		
		if(!-e $local_log_folder){
			mkdir($local_log_folder);
		}
		
		# Add full path to @find_dirs so that log files older than DELETE_LOGS_AFTER are deleted
		my $fullpath_to_local_logs = Path::Class::Dir->new(getcwd(), "logs_backup");
		push (@find_dirs, $fullpath_to_local_logs);
		
		my $log_local = $local_log_folder . "/" . $backup_file_name;
		
		# Delete the local log file if it already exists
		if(-e $log_local){
			unlink $log_local;
		}
		
		# If the log file contains UPDATE in the filename, do not allow users to see it since it will contain steam credentials
		# Will return -1 for not existing
		my $isUpdate = index($log_file,SCREEN_TYPE_UPDATE);
		
		if($isUpdate == -1){
			copy($log_file,$log_local);
		}
	}
	
	# Delete all files in @find_dirs older than DELETE_LOGS_AFTER days
	find ( sub {
		my $file = $File::Find::name;
		if ( -f $file ) {
			push (@file_list, $file);
		}
	}, @find_dirs);
 
	for my $file (@file_list) {
		my @stats = stat($file);
		if ($now-$stats[9] > $AGE) {
			unlink $file;
		}
	}
	
	move($log_file,$output_path);
	
	return 0;
}

sub create_screen_id
{
	my ($screen_type, $home_id) = @_;
	return sprintf("OGP_%s_%09d", $screen_type, $home_id);
}

sub create_screen_cmd
{
	my ($screen_id, $exec_cmd) = @_;
	$exec_cmd = replace_OGP_Vars($screen_id, $exec_cmd);
	return
	  sprintf('screen -d -m -t "%1$s" -c ' . SCREENRC_FILE . ' -S %1$s %2$s',
			  $screen_id, $exec_cmd);

}

sub create_screen_cmd_loop
{
	my ($screen_id, $exec_cmd, $priority, $affinity) = @_;
	my $server_start_batfile = $screen_id . "_startup_scr.bat";
	
	$exec_cmd = replace_OGP_Vars($screen_id, $exec_cmd);
	
	# Create batch file that will launch the process and store PID which will be used for killing later
	open (SERV_START_BAT_SCRIPT, '>', $server_start_batfile);
	
	my $batch_server_command = ":TOP" . "\r\n"
	. "set starttime=%time%" . "\r\n"
	. "start " . $priority . " " . $affinity . " /wait " . $exec_cmd . "\r\n"
	. "set endtime=%time%" . "\r\n" 
	. "set /a secs=%endtime:~6,2%" . "\r\n" 
	. "set /a secs=%secs%-%starttime:~6,2%" . "\r\n"
	. "if exist SERVER_STOPPED exit" . "\r\n"
	. "if %secs% lss 15 exit" . "\r\n"
	. "goto TOP" . "\r\n";
	
	print SERV_START_BAT_SCRIPT $batch_server_command;
	close (SERV_START_BAT_SCRIPT);
	
	my $screen_exec_script = "cmd /Q /C " . $server_start_batfile;
	
	return
	  sprintf('screen -d -m -t "%1$s" -c ' . SCREENRC_FILE . ' -S %1$s %2$s',
			  $screen_id, $screen_exec_script);

}

sub replace_OGP_Vars{
	# This function replaces constants from game server XML Configs with OGP paths for Steam Auto Updates for example
	my ($screen_id, $exec_cmd) = @_;
	my $screen_id_for_txt_update = substr ($screen_id, rindex($screen_id, '_') + 1);
	my $steamInsFile = $screen_id_for_txt_update . "_install.txt";
	my $steamCMDPath = STEAMCMD_CLIENT_DIR;
	my $fullPath = Path::Class::File->new($steamCMDPath, $steamInsFile);
	
	my $windows_steamCMDPath= `cygpath -wa $steamCMDPath`;
	chop $windows_steamCMDPath;
	$windows_steamCMDPath =~ s#/#\\#g;
	
	# If the install file exists, the game can be auto updated, else it will be ignored by the game for improper syntax
	# To generate the install file, the "Install/Update via Steam" button must be clicked on at least once!
	if(-e $fullPath){
		$exec_cmd =~ s/{OGP_STEAM_CMD_DIR}/$windows_steamCMDPath/g;
		$exec_cmd =~ s/{STEAMCMD_INSTALL_FILE}/$steamInsFile/g;
	}
	
	return $exec_cmd;
}

sub encode_list
{
	my $encoded_content = '';
	if(@_)
	{
		foreach my $line (@_)
		{
			$encoded_content .= encode_base64($line, "") . '\n';
		}
	}
	return $encoded_content;
}

sub decrypt_param
{
	my ($param) = @_;
	$param = decode_base64($param);
	$param = Crypt::XXTEA::decrypt($param, AGENT_KEY);
	$param = decode_base64($param);
	return $param;
}

sub decrypt_params
{
	my @params;
	foreach my $param (@_)
	{
		$param = &decrypt_param($param);
		push(@params, $param);
	}
	return @params;
}

sub check_steam_cmd_client
{
	if (STEAM_LICENSE ne STEAM_LICENSE_OK)
	{
		logger "Steam license not accepted, stopping Steam client check.";
		return 0;
	}
	if (!-d STEAMCMD_CLIENT_DIR && !mkdir STEAMCMD_CLIENT_DIR)
	{
		logger "Could not create " . STEAMCMD_CLIENT_DIR . " directory $!.", 1;
		exit -1;
	}
	if (!-w STEAMCMD_CLIENT_DIR)
	{
		logger "Steam client dir '"
		  . STEAMCMD_CLIENT_DIR
		  . "' not writable. Unable to get Steam client.";
		return -1;
	}
	if (!-f STEAMCMD_CLIENT_BIN)
	{
		logger "The Steam client, steamcmd, does not exist yet, installing...";
		my $steam_client_file = 'steamcmd.zip';
		my $steam_client_path = Path::Class::File->new(STEAMCMD_CLIENT_DIR, $steam_client_file);
		my $steam_client_url =
		  "http://media.steampowered.com/installer/" . $steam_client_file;
		logger "Downloading the Steam client from $steam_client_url to '"
		  . $steam_client_path . "'.";
		
		my $ua = LWP::UserAgent->new;
		$ua->agent('Mozilla/5.0');
		my $response = $ua->get($steam_client_url, ':content_file' => "$steam_client_path");
		
		unless ($response->is_success)
		{
			logger "Failed to download steam installer from "
			  . $steam_client_url
			  . ".", 1;
			return -1;
		}
		if (-f $steam_client_path)
		{
			logger "Uncompressing $steam_client_path";
			if ( uncompress_file_without_decrypt($steam_client_path, STEAMCMD_CLIENT_DIR) != 1 )
			{
				unlink($steam_client_path);
				logger "Unable to uncompress $steam_client_path, the file has been removed.";
				return -1;
			}
			unlink($steam_client_path);
		}
	}
	if (!-x STEAMCMD_CLIENT_BIN)
	{
		if ( ! chmod 0755, STEAMCMD_CLIENT_BIN )
		{
			logger "Unable to apply execution permission to ".STEAMCMD_CLIENT_BIN.".";
		}
	}
	return 1;
}

sub is_screen_running
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($screen_type, $home_id) = decrypt_params(@_);
	return is_screen_running_without_decrypt($screen_type, $home_id);
}

sub is_screen_running_without_decrypt
{
	my ($screen_type, $home_id) = @_;

	my $screen_id = create_screen_id($screen_type, $home_id);

	my $is_running = `screen -list | grep $screen_id`;

	if ($is_running =~ /^\s*$/)
	{
		return 0;
	}
	else
	{
		return 1;
	}
}

# Delete Server Stopped Status File:
sub deleteStoppedStatFile
{
	my ($home_path) = @_;
	my $server_stop_status_file = Path::Class::File->new($home_path, "SERVER_STOPPED");
	if(-e $server_stop_status_file)
	{
		unlink $server_stop_status_file;
	}
}

# Universal startup function
sub universal_start
{
	chomp(@_);
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	return universal_start_without_decrypt(decrypt_params(@_));
}

# Split to two parts because of internal calls.
sub universal_start_without_decrypt
{
	my (
		$home_id, $home_path, $server_exe, $run_dir, $startup_cmd,
		$server_port, $server_ip, $cpu,	$nice
	   ) = @_;
	   
	if (is_screen_running_without_decrypt(SCREEN_TYPE_HOME, $home_id) == 1)
	{
		logger "This server is already running (ID: $home_id).";
		return -14;
	}

	if (!-e $home_path)
	{
		logger "Can't find server's install path [ $home_path ].";
		return -10;
	}

	# Some game require that we are in the directory where the binary is.
	my $game_binary_dir = Path::Class::Dir->new($home_path, $run_dir);
	if ( -e $game_binary_dir && !chdir $game_binary_dir)
	{
		logger "Could not change to server binary directory $game_binary_dir.";
		return -12;
	}

	if (!-x $server_exe)
	{
		if (!chmod 0755, $server_exe)
		{
			logger "The $server_exe file is not executable.";
			return -13;
		}
	}

	my $screen_id = create_screen_id(SCREEN_TYPE_HOME, $home_id);

	# Create affinity and priority strings
	my $priority;
	my $affinity;
	
	if($nice ne "NA")
	{
		if( $nice <= 19 and $nice >= 11 )
		{
			$priority = "/low";
		}		
		elsif( $nice <= 10 and $nice >= 1 )
		{
			$priority = "/belownormal";
		}
		elsif( $nice == 0 )
		{
			$priority = "/normal";
		}
		elsif( $nice <= -1 and $nice >= -8  )
		{
			$priority = "/abovenormal";
		}
		elsif( $nice <= -9 and $nice >= -18 )
		{
			$priority = "/high";
		}
		elsif( $nice == -19 )
		{
			$priority = "/realtime";
		}
	}
	else
	{
		$priority = "";
	}
	
	if($cpu ne "NA" and $cpu ne "" )
	{
		
		$affinity = "/affinity $cpu";
	}
	else
	{
		$affinity = "";
	}
	
	my $win_game_binary_dir = `cygpath -wa $game_binary_dir`;
	chomp $win_game_binary_dir;
	
	# Create the startup string.
	my ($file_extension) = $server_exe =~ /(\.[^.]+)$/;
		
	my $cli_bin;
	
	# Create bash file to respawn process if it crashes or exits without user interaction
	# If a user stops the server, the process will not respawn
	
	if($file_extension eq ".jar")
	{
		if(defined($Cfg::Preferences{ogp_autorestart_server}) &&  $Cfg::Preferences{ogp_autorestart_server} eq "1"){
			deleteStoppedStatFile($home_path);
			$cli_bin = create_screen_cmd_loop($screen_id, "$startup_cmd", $priority, $affinity);
		}else{
			$cli_bin = create_screen_cmd($screen_id, "cmd /Q /C start $priority $affinity /WAIT $startup_cmd");
		}
	}
	elsif(($file_extension eq ".sh")||($file_extension eq ".bash"))
	{
		# There is no software made for windows that uses bash by default,
		# but it can be a good way to improve the server startup. To be able to use
		# sh/bash scripts as server executable I added this piece to the agent:	
		if(defined($Cfg::Preferences{ogp_autorestart_server}) &&  $Cfg::Preferences{ogp_autorestart_server} eq "1"){
			deleteStoppedStatFile($home_path);
			$cli_bin = create_screen_cmd_loop($screen_id, "bash $game_binary_dir/$server_exe $startup_cmd", $priority, $affinity);
		}else{
			$cli_bin = create_screen_cmd($screen_id, "cmd /Q /C start $priority $affinity /WAIT bash $game_binary_dir/$server_exe $startup_cmd");
		}
	}
	else
	{
		if(defined($Cfg::Preferences{ogp_autorestart_server}) &&  $Cfg::Preferences{ogp_autorestart_server} eq "1"){
			deleteStoppedStatFile($home_path);
			$cli_bin = create_screen_cmd_loop($screen_id, "$win_game_binary_dir\\$server_exe $startup_cmd", $priority, $affinity);
		}else{
			# Below line should only be used for launching non-auto restart game servers
			$win_game_binary_dir =~ s/\\/\\\\/g;
			
			$cli_bin = create_screen_cmd($screen_id, "cmd /Q /C start $priority $affinity /WAIT $win_game_binary_dir\\\\$server_exe $startup_cmd");
		}
	}
	
	$home_path =~ s/\\/\//g;
	
	my $log_file = Path::Class::File->new(SCREEN_LOGS_DIR, "screenlog.$screen_id");
	backup_home_log( $home_id, $log_file );
	
	my $clean_cli_bin = $cli_bin;
	$clean_cli_bin =~ s/\\\\/\\/g;
	logger
	  "Startup command [ $clean_cli_bin ] will be executed in dir $game_binary_dir.";

	system($cli_bin);

	# Create startup file for the server.
	my $startup_file =
	  Path::Class::File->new(GAME_STARTUP_DIR, "$server_ip-$server_port");

	if (open(STARTUP, '>', $startup_file))
	{
		print STARTUP
		  "$home_id,$home_path,$server_exe,$run_dir,$startup_cmd,$server_port,$server_ip,$cpu,$nice";
		logger "Created startup flag for $server_ip-$server_port";
		close(STARTUP);
	}
	else
	{
		logger "Cannot create file in " . $startup_file . " : $!";
	}
	return 1;
}

# Returns the number of CPUs available.
sub cpu_count
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	if (!-e "/proc/cpuinfo")
	{
		return "ERROR - Missing /proc/cpuinfo";
	}

	open(CPUINFO, '<', "/proc/cpuinfo")
	  or return "ERROR - Cannot open /proc/cpuinfo";

	my $cpu_count = 0;

	while (<CPUINFO>)
	{
		chomp;
		next if $_ !~ /^processor/;
		$cpu_count++;
	}
	close(CPUINFO);
	return "$cpu_count";
}

### File exists check ####
# Simple a way to check if a file exists using the remote agent
#
# @return 0 when file exists.
# @return 1 when file does not exist.
sub rfile_exists
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	chdir AGENT_RUN_DIR;
	my $checkFile = decrypt_param(@_);

	if (-e $checkFile)
	{
		return 0;
	}
	else
	{
		return 1;
	}
}

##### Quick check to verify agent is up and running
# Used to quickly see if the agent is online, and if the keys match.
# The message that is sent to the agent must be hello, if not then
# it is intrepret as encryption key missmatch.
#
# @return 1 when encrypted message is not 'hello'
# @return 0 when check is ok.
sub quick_chk
{
	my $dec_check = &decrypt_param(@_);
	if ($dec_check ne 'hello')
	{
		logger "ERROR - Encryption key mismatch! Returning 1 to asker.";
		return 1;
	}
	return 0;
}

### Return -10 If home path is not found.
### Return -9  If log type was invalid.
### Return -8  If log file was not found.
### 0 reserved for connection problems.
### Return 1;content If log found and screen running.
### Return 2;content If log found but screen is not running.
sub get_log
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($screen_type, $home_id, $home_path, $nb_of_lines, $log_file) = decrypt_params(@_);

	if (!chdir $home_path)
	{
		logger "Can't change to server's install path [ $home_path ].";
		return -10;
	}

	if (   ($screen_type eq SCREEN_TYPE_UPDATE)
		&& ($screen_type eq SCREEN_TYPE_HOME))
	{
		logger "Invalid screen type '$screen_type'.";
		return -9;
	}

	if(!$log_file)
	{
		my $screen_id = create_screen_id($screen_type, $home_id);
		$log_file = Path::Class::File->new(SCREEN_LOGS_DIR, "screenlog.$screen_id");
	}
	else
	{
		$log_file = Path::Class::File->new($home_path, $log_file);
	}
	
	chmod 0644, $log_file;	
	
	# Create local copy of current log file if SCREEN_LOG_LOCAL = 1
	if(SCREEN_LOG_LOCAL == 1)
	{
		my $log_local = Path::Class::File->new($home_path, "LOG_$screen_type.txt");
		if ( -e $log_local )
		{
			unlink $log_local;
		}
		
		# Copy log file only if it's not an UPDATE type as it may contain steam credentials
		if($screen_type eq SCREEN_TYPE_HOME){
			copy($log_file, $log_local);
		}
	}
	
	# Regenerate the log file if it doesn't exist
	unless ( -e $log_file )
	{
		if (open(NEWLOG, '>', $log_file))
		{
			logger "Log file missing, regenerating: " . $log_file;
			print NEWLOG "Log file missing, started new log\n";
			close(NEWLOG);
		}
		else
		{
			logger "Cannot regenerate log file in " . $log_file . " : $!";
			return -8;
		}
	}
	
	# Return a few lines of output to the web browser
	my(@modedlines) = `tail -n $nb_of_lines $log_file`;
	
	my $linecount = 0;
	
	foreach my $line (@modedlines) {
		#Text replacements to remove the Steam user login from steamcmd logs for security reasons.
		$line =~ s/login .*//g;
		$line =~ s/Logging .*//g;
		$line =~ s/set_steam_guard_code.*//g;
		$line =~ s/force_install_dir.*//g;
		#Text replacements to remove empty lines.
		$line =~ s/^ +//g;
		$line =~ s/^\t+//g;
		$line =~ s/^\e+//g;
		#Remove � from console output when master server update is running.
		$line =~ s/�//g;
		$modedlines[$linecount]=$line;
		$linecount++;
	} 
	
	my $encoded_content = encode_list(@modedlines);
	chdir AGENT_RUN_DIR;
	if(is_screen_running_without_decrypt($screen_type, $home_id) == 1)
	{
		return "1;" . $encoded_content;
	}
	else
	{
		return "2;" . $encoded_content;
	}
}

# stop server function
sub stop_server
{
	chomp(@_);
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	return stop_server_without_decrypt(decrypt_params(@_));
}

##### Stop server without decrypt
### Return 1 when error occurred on decryption.
### Return 0 on success
sub stop_server_without_decrypt
{
	my ($home_id, $server_ip, $server_port, $control_protocol,
		$control_password, $control_type, $home_path) = @_;
		
	my $startup_file = Path::Class::File->new(GAME_STARTUP_DIR, "$server_ip-$server_port");
	
	if (-e $startup_file)
	{
		logger "Removing startup flag " . $startup_file . "";
		unlink($startup_file)
		  or logger "Cannot remove the startup flag file $startup_file $!";
	}
	
	# Create file indicator that the game server has been stopped if defined
	if(defined($Cfg::Preferences{ogp_autorestart_server}) &&  $Cfg::Preferences{ogp_autorestart_server} eq "1"){
		
		# Get current directory and chdir into the game's home dir
		my $curDir = getcwd();
		chdir $home_path;

		# Create stopped indicator file used by autorestart of OGP if server crashes
		open(STOPFILE, '>', "SERVER_STOPPED");
		close(STOPFILE);
		
		# Return to original directory
		chdir $curDir;
	}
		
	my $screen_id = create_screen_id(SCREEN_TYPE_HOME, $home_id);
	my $get_screen_pid = "screen -list | grep $screen_id | cut -f1 -d'.' | sed '".'s/\W//g'."'";
	my $screen_pid = `$get_screen_pid`; 
	chomp $screen_pid;
	# Some validation checks for the variables.
	if ($server_ip =~ /^\s*$/ || $server_port < 0 || $server_port > 65535)
	{
		logger("Invalid IP:Port given $server_ip:$server_port.");
		return 1;
	}

	if ($control_password !~ /^\s*$/ and $control_protocol ne "")
	{
		if ($control_protocol eq "rcon")
		{
			use KKrcon::KKrcon;
			my $rcon = new KKrcon(
								  Password => $control_password,
								  Host	 => $server_ip,
								  Port	 => $server_port,
								  Type	 => $control_type
								 );

			my $rconCommand = "quit";
			$rcon->execute($rconCommand);
		}
		elsif ($control_protocol eq "rcon2")
		{
			use KKrcon::HL2;
			my $rcon2 = new HL2(
								  hostname => $server_ip,
								  port	 => $server_port,
								  password => $control_password,
								  timeout  => 2
								 );

			my $rconCommand = "quit";
			$rcon2->run($rconCommand);
		}
		system('screen -wipe > /dev/null 2>&1');
	}
	else
	{
		logger "Control protocol not supported. Using kill signal to stop the server.";
		my $screen_id = create_screen_id(SCREEN_TYPE_HOME, $home_id);
		system("cmd /C taskkill /f /fi 'PID eq $screen_pid' /T");
		system('screen -wipe > /dev/null 2>&1');
	}
	
	if (is_screen_running_without_decrypt(SCREEN_TYPE_HOME, $home_id) == 1)
	{
		logger "Control protocol not responding. Using kill signal.";
		system("cmd /C taskkill /f /fi 'PID eq $screen_pid' /T");
		system('screen -wipe > /dev/null 2>&1');
		logger "Server ID $home_id:Stopped server running on $server_ip:$server_port.";
		return 0;
	}
	else
	{
		logger "Server ID $home_id:Stopped server running on $server_ip:$server_port.";
		return 0;
	}
}

##### Send RCON command 
### Return 0 when error occurred on decryption.
### Return 1 on success
sub send_rcon_command
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($home_id, $server_ip, $server_port, $control_protocol,
		$control_password, $control_type, $rconCommand) = decrypt_params(@_);
	
	# legacy console
	if ($control_protocol eq "lcon")
	{
		my $screen_id = create_screen_id(SCREEN_TYPE_HOME, $home_id);
		system('screen -S '.$screen_id.' -p 0 -X stuff "'.$rconCommand.'$(printf \\\\r)"');
		logger "Sending legacy console command to ".$screen_id.": \n$rconCommand \n .";
		if ($? == 0)
		{
			my(@modedlines) = "$rconCommand";
			my $encoded_content = encode_list(@modedlines);
			return "1;" . $encoded_content;
		}
		return 0;
	}
	
	# Some validation checks for the variables.
	if ($server_ip =~ /^\s*$/ || $server_port < 0 || $server_port > 65535)
	{
		logger("Invalid IP:Port given $server_ip:$server_port.");
		return 0;
	}
	
	if ($control_password !~ /^\s*$/)
	{
		if ($control_protocol eq "rcon")
		{
			use KKrcon::KKrcon;
			my $rcon = new KKrcon(
								  Password => $control_password,
								  Host	 => $server_ip,
								  Port	 => $server_port,
								  Type	 => $control_type
								 );

			logger "Sending RCON command to $server_ip:$server_port: \n$rconCommand \n  .";
						
			my(@modedlines) = $rcon->execute($rconCommand);
			my $encoded_content = encode_list(@modedlines);
			return "1;" . $encoded_content;
		}
		else
		{		
			if ($control_protocol eq "rcon2")
			{
				use KKrcon::HL2;
				my $rcon2 = new HL2(
									  hostname => $server_ip,
									  port	 => $server_port,
									  password => $control_password,
									  timeout  => 2
									 );
				
				logger "Sending RCON command to $server_ip:$server_port: \n $rconCommand \n  .";
						
				my(@modedlines) = $rcon2->run($rconCommand);
				my $encoded_content = encode_list(@modedlines);
				return "1;" . $encoded_content;
			}
		}
	}
	else
	{
		logger "Control protocol PASSWORD NOT SET.";
		return -10;
	}
}

##### Returns a directory listing
### @return List of directories if everything OK.
### @return 0 If the directory is not found.
### @return -1 If cannot open the directory.
sub dirlist
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($datadir) = &decrypt_param(@_);
	logger "Asked for dirlist of $datadir directory.";
	if (!-d $datadir)
	{
		logger "ERROR - Directory [ $datadir ] not found!";
		return -1;
	}
	if (!opendir(DIR, $datadir))
	{
		logger "ERROR - Can't open $datadir: $!";
		return -2;
	}
	my @dirlist = readdir(DIR);
	closedir(DIR);
	return join(";", @dirlist);
}

##### Returns a directory listing with extra info the filemanager
### @return List of directories if everything OK.
### @return 1 If the directory is empty.
### @return -1 If the directory is not found.
### @return -2 If cannot open the directory.
sub dirlistfm
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my $datadir = &decrypt_param(@_);
	
	logger "Asked for dirlist of $datadir directory.";
	
	if (!-d $datadir)
	{
		logger "ERROR - Directory [ $datadir ] not found!";
		return -1;
	}
	
	if (!opendir(DIR, $datadir))
	{
		logger "ERROR - Can't open $datadir: $!";
		return -2;
	}
		
	my %dirfiles = ();
	
	my (
		$dev,  $ino,   $mode,  $nlink, $uid,	 $gid, $rdev,
		$size, $atime, $mtime, $ctime, $blksize, $blocks
	   );
	
	my $count = 0;
	
	chdir($datadir);
	
	while (readdir(DIR))
	{
		#skip the . and .. special dirs
		next if $_ eq '.';
		next if $_ eq '..';
		#print "Dir list is" . $_."\n";
		#Stat the file to get ownership and size
		(
		 $dev,  $ino,   $mode,  $nlink, $uid,	 $gid, $rdev,
		 $size, $atime, $mtime, $ctime, $blksize, $blocks
		) = stat($_);
		
		$uid = getpwuid($uid);
		$gid = getgrgid($gid);

		#This if else logic determines what it is, File, Directory, other	
		if (-T $_)
		{
			# print "File\n";
			$dirfiles{'files'}{$count}{'filename'}	= encode_base64($_);
			$dirfiles{'files'}{$count}{'size'}		= $size;
			$dirfiles{'files'}{$count}{'user'}		= $uid;
			$dirfiles{'files'}{$count}{'group'}		= $gid;
		}
		elsif (-d $_)
		{
			# print "Dir\n";
			$dirfiles{'directorys'}{$count}{'filename'}	= encode_base64($_);
			$dirfiles{'directorys'}{$count}{'size'}		= $size;
			$dirfiles{'directorys'}{$count}{'user'}		= $uid;
			$dirfiles{'directorys'}{$count}{'group'}	= $gid;
		}
		elsif (-B $_)
		{
			#print "File\n";
			$dirfiles{'binarys'}{$count}{'filename'}	= encode_base64($_);
			$dirfiles{'binarys'}{$count}{'size'}		= $size;
			$dirfiles{'binarys'}{$count}{'user'}		= $uid;
			$dirfiles{'binarys'}{$count}{'group'}		= $gid;
		}
		else
		{
			#print "Unknown\n"
			#will be listed as common files;
			$dirfiles{'files'}{$count}{'filename'}	= encode_base64($_);
			$dirfiles{'files'}{$count}{'size'}		= $size;
			$dirfiles{'files'}{$count}{'user'}		= $uid;
			$dirfiles{'files'}{$count}{'group'}		= $gid;
		}
		$count++;
	}
	closedir(DIR);
	
	if ($count eq 0)
	{
		logger "Empty directory $datadir.";
		return 1;
	}
		
	chdir AGENT_RUN_DIR;
	#Now we return it to the webpage, as array
	return {%dirfiles};
}

###### Returns the contents of a text file
sub readfile
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	chdir AGENT_RUN_DIR;
	my $userfile = &decrypt_param(@_);

	unless ( -e $userfile )
	{
		if (open(BLANK, '>', $userfile))
		{
			close(BLANK);
		}
	}
	
	if (!open(USERFILE, '<', $userfile))
	{
		logger "ERROR - Can't open file $userfile for reading.";
		return -1;
	}

	my ($wholefile, $buf);

	while (read(USERFILE, $buf, 60 * 57))
	{
		$wholefile .= encode_base64($buf);
	}
	close(USERFILE);
	
	if(!defined $wholefile)
	{
		return "1; ";
	}
	
	return "1;" . $wholefile;
}

###### Backs up file, then writes data to new file
### @return 1 On success
### @return 0 In case of a failure
sub writefile
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	chdir AGENT_RUN_DIR;
	# $writefile = file we're editing, $filedata = the contents were writing to it
	my ($writefile, $filedata) = &decrypt_params(@_);
	if (!-e $writefile)
	{
		open FILE, ">", $writefile;
	}
	else
	{
		# backup the existing file
		logger
		  "Backing up file $writefile to $writefile.bak before writing new databefore writing new data.";
		if (!copy("$writefile", "$writefile.bak"))
		{
			logger
			  "ERROR - Failed to backup $writefile to $writefile.bak. Error: $!";
			return 0;
		}
	}
	if (!-w $writefile)
	{
		logger "ERROR - File [ $writefile ] is not writeable!";
		return 0;
	}
	if (!open(WRITER, '>', $writefile))
	{
		logger "ERROR - Failed to open $writefile for writing.";
		return 0;
	}
	$filedata = decode_base64($filedata);
	$filedata =~ s/\r//g;
	print WRITER "$filedata";
	close(WRITER);
	logger "Wrote $writefile successfully!";
	return 1;
}

###### Reboots the server remotely through panel
### @return 1 On success
### @return 0 In case of a failure
sub rebootnow
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	system('shutdown -r -t 10');
	logger "Scheduled system reboot to occur in 10 seconds successfully!";
	return 1;
}

# Determine the os of the agent machine.
sub what_os
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	logger "Asking for OS type";
	my $ret = system('which uname >/dev/null 2>&1');
	if ($ret eq 0)
	{
		my $os = `\$(which uname) -a`;
		chomp $os;
		logger "OS is $os";
		return "$os";
	}
	else
	{
		logger "Cannot determine OS..that is odd";
		return "Unknown";
	}
}

### @return PID of the download process if started succesfully.
### @return -1 If could not create temporary download directory.
### @return -2 If could not create destination directory.
### @return -3 If resources unavailable.
sub start_file_download
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($url, $destination, $filename, $action, $post_script) = &decrypt_params(@_);
	logger
	  "Starting to download URL $url. Destination: $destination - Filename: $filename";

	if (!-e $destination)
	{
		logger "Creating destination directory.";
		if (!mkpath $destination )
		{
			logger "Could not create destination '$destination' directory : $!";
			return -2;
		}
	}
	
	my $download_file_path = Path::Class::File->new($destination, "$filename");

	my $pid = fork();
	if (not defined $pid)
	{
		logger "Could not allocate resources for download.";
		return -3;
	}

	# Only the forked child goes here.
	elsif ($pid == 0)
	{
		my $ua = LWP::UserAgent->new( ssl_opts => { verify_hostname => 0,
													SSL_verify_mode => 0x00 } );
		$ua->agent('Mozilla/5.0');
		my $response = $ua->get($url, ':content_file' => "$download_file_path");
		
		if ($response->is_success)
		{
			logger "Successfully fetched $url and stored it to $download_file_path. Retval: ".$response->status_line;
			
			if (!-e $download_file_path)
			{
				logger "File $download_file_path does not exist.";
				exit(0);
			}

			if ($action eq "uncompress")
			{
				logger "Starting file uncompress as ordered.";
				uncompress_file_without_decrypt($download_file_path,
												$destination);
			}
		}
		else
		{
			logger
			  "Unable to fetch $url, or save to $download_file_path. Retval: ".$response->status_line;
			exit(0);
		}

		# Child process must exit.
		exit(0);
	}
	else
	{
		if ($post_script ne "")
		{
			logger "Running postscript commands.";
			my @postcmdlines = split /[\r\n]+/, $post_script;
			my $postcmdfile = $destination."/".'postinstall.sh';
			open  FILE, '>', $postcmdfile;
			print FILE "cd $destination\n";
			print FILE "while kill -0 $pid >/dev/null 2>&1\n";
			print FILE "do\n";
			print FILE "	sleep 1\n";
			print FILE "done\n";
			foreach my $line (@postcmdlines) {
				print FILE "$line\n";
			}
			print FILE "rm -f $destination/postinstall.sh\n";
			close FILE;
			chmod 0755, $postcmdfile;
			my $screen_id = create_screen_id("post_script", $pid);
			my $cli_bin = create_screen_cmd($screen_id, "bash $postcmdfile");
			system($cli_bin);
		}
		logger "Download process for $download_file_path has pid number $pid.";
		return "$pid";
	}
}

sub check_b4_chdir
{
	my ( $path ) = @_;
		
	if (!-e $path)
	{
		logger "$path does not exist yet. Trying to create it...";

		if (!mkpath($path))
		{
			logger "Error creating $path . Errno: $!";
			return -1;
		}
	}
	
	if (!chdir $path)
	{
		logger "Unable to change dir to '$path'.";
		return -1;
	}
	
	return 0;
}

sub create_bash_scripts
{
	my ( $home_path, $bash_scripts_path, $precmd, $postcmd, @installcmds ) = @_;
	
	$home_path         =~ s/('+)/'\"$1\"'/g;
	$bash_scripts_path =~ s/('+)/'\"$1\"'/g;
	
	my @precmdlines = split /[\r\n]+/, $precmd;
	my $precmdfile = 'preinstall.sh';
	open  FILE, '>', $precmdfile;
	print FILE "cd '$home_path'\n";
	foreach my $line (@precmdlines) {
		print FILE "$line\n";
	}
	close FILE;
	chmod 0755, $precmdfile;
	
	my @postcmdlines = split /[\r\n]+/, $postcmd;
	my $postcmdfile = 'postinstall.sh';
	open  FILE, '>', $postcmdfile;
	print FILE "cd '$home_path'\n";
	foreach my $line (@postcmdlines) {
		print FILE "$line\n";
	}
	print FILE "cd '$bash_scripts_path'\n".
			   "rm -f preinstall.sh\n".
			   "rm -f postinstall.sh\n".
			   "rm -f runinstall.sh\n";
	close FILE;
	chmod 0755, $postcmdfile;
	
	my $installfile = 'runinstall.sh';
	open  FILE, '>', $installfile;
	print FILE "#!/bin/bash\n".
			   "cd '$bash_scripts_path'\n".
			   "./$precmdfile\n";
	foreach my $installcmd (@installcmds)
	{
		print FILE "$installcmd\n";
	}
	print FILE "wait ".'${!}'."\n".
			   "cd '$bash_scripts_path'\n".
			   "./$postcmdfile\n";
	close FILE;
	chmod 0755, $installfile;
	
	return $installfile;
}

#### Run the rsync update ####
### @return 1 If update started
### @return 0 In error case.
sub start_rsync_install
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($home_id, $home_path, $url, $exec_folder_path, $exec_path, $precmd, $postcmd) = decrypt_params(@_);

	if ( check_b4_chdir($home_path) != 0)
	{
		return 0;
	}

	my $bash_scripts_path = MANUAL_TMP_DIR . "/home_id_" . $home_id;
	
	if ( check_b4_chdir($bash_scripts_path) != 0)
	{
		return 0;
	}
	
	# Rsync install require the rsync binary to exist in the system
	# to enable this functionality.
	my $rsync_binary = Path::Class::File->new("/usr/bin", "rsync");
	
	if (!-f $rsync_binary)
	{
		logger "Failed to start rsync update from "
		  . $url
		  . " to $home_path. Error: Rsync client not installed.";
		return 0;
	}

	my $screen_id = create_screen_id(SCREEN_TYPE_UPDATE, $home_id);
	
	my $log_file = Path::Class::File->new(SCREEN_LOGS_DIR, "screenlog.$screen_id");
	
	backup_home_log( $home_id, $log_file );
	
	my $path	= $home_path;
	$path		=~ s/('+)/'\"$1\"'/g;
	my @installcmds = ("/usr/bin/rsync --archive --compress --copy-links --update --verbose rsync://$url '$path'", 
					   "cd '$path'",
					   "find -iname \\\*.exe -exec chmod -f +x {} \\\;", 
					   "find -iname \\\*.bat -exec chmod -f +x {} \\\;");
	my $installfile = create_bash_scripts( $home_path, $bash_scripts_path, $precmd, $postcmd, @installcmds );

	my $screen_cmd = create_screen_cmd($screen_id, "./$installfile");
	logger "Running rsync update: /usr/bin/rsync --archive --compress --copy-links --update --verbose rsync://$url '$home_path'";
	system($screen_cmd);
	
	chdir AGENT_RUN_DIR;
	return 1;
}

### @return PID of the download process if started succesfully.
### @return -1 If could not create temporary download directory.
### @return -2 If could not create destination directory.
### @return -3 If resources unavailable.
sub master_server_update
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($home_id,$home_path,$ms_home_id,$ms_home_path,$exec_folder_path,$exec_path,$precmd,$postcmd) = decrypt_params(@_);
	
	if ( check_b4_chdir($home_path) != 0)
	{
		return 0;
	}
			
	my $bash_scripts_path = MANUAL_TMP_DIR . "/home_id_" . $home_id;
	
	if ( check_b4_chdir($bash_scripts_path) != 0)
	{
		return 0;
	}

	my $screen_id = create_screen_id(SCREEN_TYPE_UPDATE, $home_id);
	
	my $log_file = Path::Class::File->new(SCREEN_LOGS_DIR, "screenlog.$screen_id");
	
	backup_home_log( $home_id, $log_file );
	
	my $my_home_path = $home_path;
	$my_home_path =~ s/('+)/'\"$1\"'/g;
	$ms_home_path =~ s/('+)/'\"$1\"'/g;
	
	my @installcmds = ("cp -vuRf  '$ms_home_path'/* '$my_home_path'");
	my $installfile = create_bash_scripts( $home_path, $bash_scripts_path, $precmd, $postcmd, @installcmds );

	my $screen_cmd = create_screen_cmd($screen_id, "./$installfile");
	logger "Running master server update from home ID $home_id to home ID $ms_home_id";
	system($screen_cmd);
	
	chdir AGENT_RUN_DIR;
	return 1;
}

#### Run the steam client ####
### @return 1 If update started
### @return 0 In error case.
sub steam_cmd
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($home_id, $home_path, $mod, $modname, $betaname, $betapwd, $user, $pass, $guard, $exec_folder_path, $exec_path, $precmd, $postcmd, $cfg_os) = decrypt_params(@_);
	
	# Creates home path if it doesn't exist
	if ( check_b4_chdir($home_path) != 0)
	{
		return 0;
	}
  
    # Changes into root steamcmd OGP directory
	if ( check_b4_chdir(STEAMCMD_CLIENT_DIR) != 0)
	{
		return 0;
	}
	
	my $screen_id = create_screen_id(SCREEN_TYPE_UPDATE, $home_id);
	my $screen_id_for_txt_update = substr ($screen_id, rindex($screen_id, '_') + 1);
	my $steam_binary = Path::Class::File->new(STEAMCMD_CLIENT_DIR, "steamcmd.exe");
	my $installSteamFile = $screen_id_for_txt_update . "_install.txt";
	
	my $windows_home_path = `cygpath -wa $home_path`;
	chop $windows_home_path;
	
	my $installtxt = Path::Class::File->new($installSteamFile);
	
	open  FILE, '>', $installtxt;
	print FILE "\@ShutdownOnFailedCommand 1\n";
	print FILE "\@NoPromptForPassword 1\n";
	if($guard ne '')
	{
		print FILE "set_steam_guard_code $guard\n";
	}
	if($user ne '' && $user ne 'anonymous')
	{
		print FILE "login $user $pass\n";
	}
	else
	{
		print FILE "login anonymous\n";
	}
	
	print FILE "force_install_dir \"$windows_home_path\"\n";
	
	if($modname ne "")
	{
		print FILE "app_set_config $mod mod $modname\n";
		print FILE "app_update $mod mod $modname validate\n";
	}

	if($betaname ne "" && $betapwd ne "")
	{
		print FILE "app_update $mod -beta $betaname -betapassword $betapwd\n";
	}
	elsif($betaname ne "" && $betapwd eq "")
	{
		print FILE "app_update $mod -beta $betaname\n";
	}
	else
	{
		print FILE "app_update $mod\n";
	}
	
	print FILE "exit\n";
	close FILE;
  
    my $bash_scripts_path = MANUAL_TMP_DIR . "/home_id_" . $home_id;
	
	if ( check_b4_chdir($bash_scripts_path) != 0)
	{
		return 0;
	}
	
	my $log_file = Path::Class::File->new(SCREEN_LOGS_DIR, "screenlog.$screen_id");
	backup_home_log( $home_id, $log_file );
	
	my $postcmd_mod = $postcmd;
	my @installcmds = ("$steam_binary +runscript $installtxt +exit");
	my $installfile = create_bash_scripts( $home_path, $bash_scripts_path, $precmd, $postcmd_mod, @installcmds );
	
	my $screen_cmd = create_screen_cmd($screen_id, "./$installfile");
	logger "Running steam update: $steam_binary +runscript $installtxt +exit";
	system($screen_cmd);

	return 1;
}

sub rsync_progress
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($running_home) = &decrypt_param(@_);
	logger "User requested progress on rsync job on home $running_home.";
	if (-r $running_home)
	{
		$running_home =~ s/('+)/'"$1"'/g;
		my $progress = `du -sk '$running_home'`;
		chomp($progress);
		my ($bytes, $junk) = split(/\s+/, $progress);
		logger("Found $bytes and $junk");
		return $bytes;
	}
	return "0";
}

sub is_file_download_in_progress
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($pid) = &decrypt_param(@_);
	logger "User requested if download is in progress with pid $pid.";
	my @pids = `ps -ef`;
	@pids = grep(/$pid/, @pids);
	logger "Number of pids for file download: @pids";
	if (@pids > '0')
	{
		return 1;
	}
	return 0;
}

### \return 1 If file is uncompressed succesfully.
### \return 0 If file does not exist.
### \return -1 If file could not be uncompressed.
sub uncompress_file
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	return uncompress_file_without_decrypt(decrypt_params(@_));
}

sub uncompress_file_without_decrypt
{

	# File must include full path.
	my ($file, $destination) = @_;

	logger "Uncompression called for file $file to dir $destination.";

	if (!-e $file)
	{
		logger "File $file could not be found for uncompression.";
		return 0;
	}

	if (!-e $destination)
	{
		mkpath($destination, {error => \my $err});
		if (@$err)
		{
			logger "Failed to create destination dir $destination.";
			return 0;
		}
	}

	my $ae = Archive::Extract->new(archive => $file);

	if (!$ae)
	{
		logger "Could not create archive instance for file $file.";
		return -1;
	}

	my $ok = $ae->extract(to => $destination);

	if (!$ok)
	{
		logger "File $file could not be uncompressed.";
		return -1;
	}

	system("chmod -Rf 755 $destination");
	system("cd $destination && find -iname \\\*.exe -exec chmod -f +x {} \\\;");
	system("cd $destination && find -iname \\\*.bat -exec chmod -f +x {} \\\;");

	logger "File uncompressed/extracted successfully.";
	return 1;
}

### \return 1 If files are compressed succesfully.
### \return -1 If files could not be compressed.
sub compress_files
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	return compress_files_without_decrypt(decrypt_params(@_));
}

sub compress_files_without_decrypt
{
	my ($files,$destination,$archive_name,$archive_type) = @_;

	if (!-e $destination)
	{
		logger "compress_files: Destination path ( $destination ) could not be found.";
		return -1;
	}
	
	chdir $destination;
	my @items = split /\Q\n/, $files;
	my @inventory;
	if($archive_type eq "zip")
	{
		logger $archive_type." compression called, destination archive is: $destination$archive_name.$archive_type";
		my $zip = Archive::Zip->new();
		foreach my $item (@items) {
			if(-e $item)
			{
				if (-f $item)
				{
					$zip->addFile( $item );
				}
				elsif (-d $item)
				{
					$zip->addTree( $item, $item );
				} 
			}
		}
		# Save the file
		unless ( $zip->writeToFileNamed($archive_name.'.zip') == AZ_OK ) {
			logger "Write Error at $destination/$archive_name.$archive_type";
			return -1
		}
		logger $archive_type." archive $destination$archive_name.$archive_type created successfully";
		return 1;
	}
	elsif($archive_type eq "tbz")
	{
		logger $archive_type." compression called, destination archive is: $destination$archive_name.$archive_type";
		my $tar = Archive::Tar->new;
		foreach my $item (@items) {
			if(-e $item)
			{
				if (-f $item)
				{
					$tar->add_files( $item );
				}
				elsif (-d $item)
				{
					@inventory = ();
					find (sub { push @inventory, $File::Find::name }, $item);
					$tar->add_files( @inventory );
				} 
			}
		}
		# Save the file
		unless ( $tar->write("$archive_name.$archive_type", COMPRESS_BZIP) ) {
			logger "Write Error at $destination/$archive_name.$archive_type";
			return -1
		}
		logger $archive_type." archive $destination$archive_name.$archive_type created successfully";
		return 1;
	}
	elsif($archive_type eq "tgz")
	{
		logger $archive_type." compression called, destination archive is: $destination$archive_name.$archive_type";
		my $tar = Archive::Tar->new;
		foreach my $item (@items) {
			if(-e $item)
			{
				if (-f $item)
				{
					$tar->add_files( $item );
				}
				elsif (-d $item)
				{
					@inventory = ();
					find (sub { push @inventory, $File::Find::name }, $item);
					$tar->add_files( @inventory );
				} 
			}
		}
		# Save the file
		unless ( $tar->write("$archive_name.$archive_type", COMPRESS_GZIP) ) {
			logger "Write Error at $destination/$archive_name.$archive_type";
			return -1
		}
		logger $archive_type." archive $destination$archive_name.$archive_type created successfully";
		return 1;
	}
	elsif($archive_type eq "tar")
	{
		logger $archive_type." compression called, destination archive is: $destination$archive_name.$archive_type";
		my $tar = Archive::Tar->new;
		foreach my $item (@items) {
			if(-e $item)
			{
				if (-f $item)
				{
					$tar->add_files( $item );
				}
				elsif (-d $item)
				{
					@inventory = ();
					find (sub { push @inventory, $File::Find::name }, $item);
					$tar->add_files( @inventory );
				} 
			}
		}
		# Save the file
		unless ( $tar->write("$archive_name.$archive_type") ) {
			logger "Write Error at $destination/$archive_name.$archive_type";
			return -1
		}
		logger $archive_type." archive $destination$archive_name.$archive_type created successfully";
		return 1;
	}
	elsif($archive_type eq "bz2")
	{
		logger $archive_type." compression called.";
		foreach my $item (@items) {
			if(-e $item)
			{
				if (-f $item)
				{
					bzip2 $item => "$item.bz2";
				}
				elsif (-d $item)
				{
					@inventory = ();
					find (sub { push @inventory, $File::Find::name }, $item);
					foreach my $relative_item (@inventory) {
						bzip2 $relative_item => "$relative_item.bz2";
					}
				}
			}
		}
		logger $archive_type." archives created successfully at $destination";
		return 1;
	}
}

sub discover_ips
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($check) = decrypt_params(@_);

	if ($check ne "chk")
	{
		logger "Invalid parameter '$check' given for discover_ips function.";
		return "";
	}
	
	my $iplist = "";
	
	my @data = `ipconfig /all`;

	foreach my $temp (@data)
	{
		if ($temp =~ /ip.+: (\d+\.\d+\.\d+\.\d+)/si)
		{
			chomp $1;
			logger "Found an IP $1";
			$iplist .= "$1,";
		}
	}
	logger "IPlist is $iplist";
	chop $iplist;
	return "$iplist";
}

### Return -1 In case of invalid param
### Return 1;content in case of success
sub mon_stats
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($mon_stats) = decrypt_params(@_);
	if ($mon_stats ne "mon_stats")
	{
		logger "Invalid parameter '$mon_stats' given for $mon_stats function.";
		return -1;
	}

	my @disk			= `df -hP -x tmpfs`;
	my $encoded_content = encode_list(@disk);
	my @uptime		  = `net stats srv`;
	$encoded_content .= encode_list(@uptime);
	return "1;$encoded_content";
}

sub exec
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($command) = decrypt_params(@_);
	my @cmdret		   = `$command 2>/dev/null`;
	my $encoded_content = encode_list(@cmdret);
	return "1;$encoded_content";
}

# used in conjunction with the clone_home feature in the web panel
# this actually does the file copies
sub clone_home
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($source_home, $dest_home, $owner) = decrypt_params(@_);
	my ($time_start, $time_stop, $time_diff);
	logger "Copying from $source_home to $dest_home...";

	# check size of source_home, make sure we have space to copy
	if (!-e $source_home)
	{
		logger "ERROR - $source_home does not exist";
		return 0;
	}
	logger "Game home $source_home exists...copy will proceed";

	# start the copy, and a timer
	$time_start = time();
	if (!dircopy("$source_home", "$dest_home"))
	{
		$time_stop = time();
		$time_diff = $time_stop - $time_start;
		logger
		  "Error occured after $time_diff seconds during copy of $source_home to $dest_home - $!";
		return 0;
	}
	else
	{
		$time_stop = time();
		$time_diff = $time_stop - $time_start;
		logger
		  "Home clone completed successfully to $dest_home in $time_diff seconds";
		return 1;
	}
}

# used to delete the game home from the file system when it's removed from the panel
sub remove_home
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($home_path_del) = decrypt_params(@_);

	if (!-e $home_path_del)
	{
		logger "ERROR - $home_path_del does not exist...nothing to do";
		return 0;
	}

	sleep 1 while ( !pathrmdir("$home_path_del") );

	logger "Deletetion of $home_path_del successful!";
	return 1;
}

sub restart_server
{
	chomp(@_);
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	return restart_server_without_decrypt(decrypt_params(@_));
}

### Restart the server
## return -2 CANT STOP
## return -1  CANT START (no startup file found that mach the home_id, port and ip)
## return 1 Restart OK
sub restart_server_without_decrypt
{
	my ($home_id, $server_ip, $server_port, $control_protocol,
		$control_password, $control_type, $home_path, $server_exe, $run_dir,
		$cmd, $cpu, $nice) = @_;

	if (stop_server_without_decrypt($home_id, $server_ip, 
									$server_port, $control_protocol,
									$control_password, $control_type, $home_path) == 0)
	{
		if (universal_start_without_decrypt($home_id, $home_path, $server_exe, $run_dir,
											$cmd, $server_port, $server_ip, $cpu, $nice) == 1)
		{
			return 1;
		}
		else
		{
			return -1;
		}
	}
	else
	{
		return -2;
	}
}

sub sudo_exec
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my $sudo_exec = &decrypt_param(@_);
	return sudo_exec_without_decrypt($sudo_exec);
}

sub sudo_exec_without_decrypt
{
	my ($command) = @_;
	my @cmdret = `$command`;
	if ($? == 0)
	{
		return "1;".encode_list(@cmdret);
	}
	return 0;
}

sub secure_path
{   
	return "1;";
}

sub get_chattr
{
	return "1;";
}

sub ftp_mgr
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($action, $login, $password, $home_path) = decrypt_params(@_);
	
	if(!defined($Cfg::Preferences{ogp_manages_ftp}) || (defined($Cfg::Preferences{ogp_manages_ftp}) &&  $Cfg::Preferences{ogp_manages_ftp} eq "1")){
		if( defined($Cfg::Preferences{ftp_method}) && $Cfg::Preferences{ftp_method} eq "FZ")
		{
			require Cfg::FileZilla;   # Use Filezilla Configuration file
			if( !defined($Cfg::FileZilla{fz_exe}) || !defined($Cfg::FileZilla{fz_xml}) || !-e "$Cfg::FileZilla{fz_exe}" || !-e "$Cfg::FileZilla{fz_xml}" )
			{
				return 0;
			}
			use Digest::MD5 qw(md5_hex);
			require XML::Simple;

			my $xml = new XML::Simple;
			my $data = $xml->XMLin( $Cfg::FileZilla{fz_xml}, 
									ForceArray => ['User','Permission','IpFilter','Allowed','Disallowed','IP','Item'],
									ForceContent => 0,
									KeepRoot => 1,
									KeyAttr => ['Item'],
									SuppressEmpty => 0 );

			my @users;
			if( defined($data->{'FileZillaServer'}->{'Users'}) )
			{
				@users = @{ $data->{'FileZillaServer'}->{'Users'}->{'User'} };
			}
			my $encoded_content;

			if($action eq "list")
			{
				if( grep {defined($_)} @users )
				{
					my (@list,$username,$dir);
					my $i=0;
					for (@users) {
						$username = $_->{'Name'};
						$dir = $_->{'Permissions'}->{'Permission'}[0]->{'Dir'};
						$dir = `cygpath -u "$dir"`;
						$list[$i++] = $username."\t".$dir."\n";
					}
					$encoded_content = encode_list(@list);
					return "1;$encoded_content";
				}
			}
			elsif($action eq "userdel")
			{
				if( grep {defined($_)} @users )
				{
					for (keys @users) {
						if($users[$_]->{'Name'} eq $login)
						{
							splice($data->{'FileZillaServer'}->{'Users'}->{'User'},$_,1);
							last;
						}
					}

					$xml->XMLout( $data,
								  OutputFile => $Cfg::FileZilla{fz_xml},
								  KeepRoot => 1,
								  NoSort => 0,
								  SuppressEmpty => 0 );

					my @args = ($Cfg::FileZilla{fz_exe}, "/reload-config");
					system(@args);
				}
			}
			elsif($action eq "useradd")
			{
				my $win_home_path = `cygpath -wa "$home_path"`;
				chomp $win_home_path;
				my $n;

				if( grep {defined($_)} @users )
				{
					$n = scalar(@users);
				}
				else
				{
					$n = 0;
				}

				$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Name'} = $login;
				$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Option'}[0]->{'content'} = md5_hex($password);
				$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Option'}[0]->{'Name'} = 'Pass';
				$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Option'}[1]->{'Name'} = 'Group';
				$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Option'}[2]->{'content'} = '0';
				$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Option'}[2]->{'Name'} = 'Bypass server userlimit';
				$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Option'}[3]->{'content'} = '0';
				$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Option'}[3]->{'Name'} = 'User Limit';
				$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Option'}[4]->{'content'} = '0';
				$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Option'}[4]->{'Name'} = 'IP Limit';
				$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Option'}[5]->{'content'} = '1';
				$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Option'}[5]->{'Name'} = 'Enabled';
				$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Option'}[6]->{'Name'} = 'Comments';
				$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Option'}[7]->{'content'} = '0';
				$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Option'}[7]->{'Name'} = 'ForceSsl';
				$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Option'}[8]->{'content'} = '0';
				$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Option'}[8]->{'Name'} = '8plus3';
				$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'IpFilter'}[0]->{'Disallowed'}[0] = undef;
				$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'IpFilter'}[0]->{'Allowed'}[0] = undef;
				$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Permissions'}->{'Permission'}[0]->{'Option'}[0]->{'content'} = '1';
				$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Permissions'}->{'Permission'}[0]->{'Option'}[0]->{'Name'} = 'FileRead';
				$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Permissions'}->{'Permission'}[0]->{'Option'}[1]->{'content'} = '1';
				$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Permissions'}->{'Permission'}[0]->{'Option'}[1]->{'Name'} = 'FileWrite';
				$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Permissions'}->{'Permission'}[0]->{'Option'}[2]->{'content'} = '1';
				$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Permissions'}->{'Permission'}[0]->{'Option'}[2]->{'Name'} = 'FileDelete';
				$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Permissions'}->{'Permission'}[0]->{'Option'}[3]->{'content'} = '1';
				$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Permissions'}->{'Permission'}[0]->{'Option'}[3]->{'Name'} = 'FileAppend';
				$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Permissions'}->{'Permission'}[0]->{'Option'}[4]->{'content'} = '1';
				$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Permissions'}->{'Permission'}[0]->{'Option'}[4]->{'Name'} = 'DirCreate';
				$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Permissions'}->{'Permission'}[0]->{'Option'}[5]->{'content'} = '1';
				$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Permissions'}->{'Permission'}[0]->{'Option'}[5]->{'Name'} = 'DirDelete';
				$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Permissions'}->{'Permission'}[0]->{'Option'}[6]->{'content'} = '1';
				$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Permissions'}->{'Permission'}[0]->{'Option'}[6]->{'Name'} = 'DirList';
				$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Permissions'}->{'Permission'}[0]->{'Option'}[7]->{'content'} = '1';
				$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Permissions'}->{'Permission'}[0]->{'Option'}[7]->{'Name'} = 'DirSubdirs';
				$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Permissions'}->{'Permission'}[0]->{'Option'}[8]->{'content'} = '1';
				$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Permissions'}->{'Permission'}[0]->{'Option'}[8]->{'Name'} = 'IsHome';
				$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Permissions'}->{'Permission'}[0]->{'Option'}[9]->{'content'} = '1';
				$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Permissions'}->{'Permission'}[0]->{'Option'}[9]->{'Name'} = 'AutoCreate';
				$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Permissions'}->{'Permission'}[0]->{'Dir'} = $win_home_path;
				$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'SpeedLimits'}->{'DlType'} = '0';
				$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'SpeedLimits'}->{'DlLimit'} = '100';
				$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'SpeedLimits'}->{'ServerDlLimitBypass'} = '0';
				$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'SpeedLimits'}->{'UlType'} = '0';
				$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'SpeedLimits'}->{'UlLimit'} = '100';
				$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'SpeedLimits'}->{'ServerUlLimitBypass'} = '0';
				$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'SpeedLimits'}->{'Upload'}[0] = undef;
				$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'SpeedLimits'}->{'Download'}[0] = undef;

				$xml->XMLout( $data,
							  OutputFile => $Cfg::FileZilla{fz_xml},
							  KeepRoot => 1,
							  NoSort => 0,
							  SuppressEmpty => 0 );

				my @args = ($Cfg::FileZilla{fz_exe}, "/reload-config");
				system(@args);
			}
			elsif($action eq "passwd")
			{
				if( grep {defined($_)} @users )
				{
					for (keys @users) {
						if($users[$_]->{'Name'} eq $login)
						{
							$data->{'FileZillaServer'}->{'Users'}->{'User'}[$_]->{'Option'}[0]->{'content'} = md5_hex($password);
							last;
						}
					}
					$xml->XMLout( $data,
								  OutputFile => $Cfg::FileZilla{fz_xml},
								  KeepRoot => 1,
								  NoSort => 0,
								  SuppressEmpty => 0 );

					my @args = ($Cfg::FileZilla{fz_exe}, "/reload-config");
					system(@args);
				}
			}
			elsif($action eq "show")
			{
				if( grep {defined($_)} @users )
				{
					my (@list,@options,@dir_options,$speed_limmits);
					for (@users) {
						if($login eq $_->{'Name'})
						{
							no warnings 'uninitialized';
							my $i=0;
							$speed_limmits = $_->{'SpeedLimits'};
							while ( my ($key, $value) = each(%$speed_limmits) )
							{
								next if $key =~ /Download|Upload/;
								$list[$i++] = $key." : ".$value."\n";
							}
							@options = @{ $_->{'Option'} };
							for(@options)
							{
								next if $_->{'Name'} eq "Pass";
								$list[$i++] = $_->{'Name'}." : ".$_->{'content'}."\n";
							}
							@dir_options = @{ $_->{'Permissions'}->{'Permission'}[0]->{'Option'} };
							for(@dir_options)
							{
								$list[$i++] = $_->{'Name'}." : ".$_->{'content'}."\n";
							}
							last;
						}
					}
					$encoded_content = encode_list(@list);
					return "1;$encoded_content";
				}
			}
			elsif($action eq "usermod")
			{
				if( grep {defined($_)} @users )
				{
					my $n;
					for (keys @users) {
						if($users[$_]->{'Name'} eq $login)
						{
							$n = $_;
							last;
						}
					}

					if( defined($n) )
					{
						my @account_settings = split /[\n]+/, $password;
						foreach my $setting (@account_settings) {
							my ($key, $value) = split /[\t]+/, $setting;
							if( $value ne "" && $value =~ /^\d+?$/)
							{
								if( $key eq 'DlType' && $value =~ /^[0-3]$/ )
								{
									$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'SpeedLimits'}->{'DlType'} = $value;
								}
								elsif( $key eq 'UlType' )
								{
									$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'SpeedLimits'}->{'UlType'} = $value;
								}

								if( $value =~ /^[0-1]$/ )
								{
									if( $key eq 'ServerUlLimitBypass' )
									{
										$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'SpeedLimits'}->{'ServerUlLimitBypass'} = $value;
									}
									elsif( $key eq 'ServerDlLimitBypass' )
									{
										$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'SpeedLimits'}->{'ServerDlLimitBypass'} = $value;
									}
									elsif( $key eq 'Bypass_server_userlimit' )
									{
										$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Option'}[2]->{'content'} = $value;
									}
									elsif( $key eq 'Enabled' )
									{
										$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Option'}[5]->{'content'} = $value;
									}
									elsif( $key eq 'ForceSsl' )
									{
										$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Option'}[7]->{'content'} = $value;
									}
									elsif( $key eq '8plus3' )
									{
										$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Option'}[8]->{'content'} = $value;
									}
									elsif( $key eq 'FileRead' )
									{
										$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Permissions'}->{'Permission'}[0]->{'Option'}[0]->{'content'} = $value;
									}
									elsif( $key eq 'FileWrite' )
									{
										$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Permissions'}->{'Permission'}[0]->{'Option'}[1]->{'content'} = $value;
									}
									elsif( $key eq 'FileDelete' )
									{
										$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Permissions'}->{'Permission'}[0]->{'Option'}[2]->{'content'} = $value;
									}
									elsif( $key eq 'FileAppend' )
									{
										$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Permissions'}->{'Permission'}[0]->{'Option'}[3]->{'content'} = $value;
									}
									elsif( $key eq 'DirCreate' )
									{
										$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Permissions'}->{'Permission'}[0]->{'Option'}[4]->{'content'} = $value;
									}
									elsif( $key eq 'DirDelete' )
									{
										$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Permissions'}->{'Permission'}[0]->{'Option'}[5]->{'content'} = $value;
									}
									elsif( $key eq 'DirList' )
									{
										$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Permissions'}->{'Permission'}[0]->{'Option'}[6]->{'content'} = $value;
									}
									elsif( $key eq 'DirSubdirs' )
									{
										$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Permissions'}->{'Permission'}[0]->{'Option'}[7]->{'content'} = $value;
									}
									elsif( $key eq 'IsHome' )
									{
										$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Permissions'}->{'Permission'}[0]->{'Option'}[8]->{'content'} = $value;
									}
									elsif( $key eq 'AutoCreate' )
									{
										$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Permissions'}->{'Permission'}[0]->{'Option'}[9]->{'content'} = $value;
									}
								}

								if( $value =~ /^[1-9][0-9]{0,8}$|^1000000000$/ )
								{
									if( $key eq 'DlLimit' )
									{
										$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'SpeedLimits'}->{'DlLimit'} = $value;
									}
									elsif( $key eq 'UlLimit' )
									{
										$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'SpeedLimits'}->{'UlLimit'} = $value;
									}
								}

								if( $key eq 'User_Limit' )
								{
									$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Option'}[3]->{'content'} = $value;
								}
								elsif( $key eq 'IP_Limit' )
								{
									$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Option'}[4]->{'content'} = $value;
								}
							}

							if( $key eq 'Comments' )
							{
								$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Option'}[6]->{'content'} = $value;
							}
							elsif( $key eq 'Group' )
							{
								$data->{'FileZillaServer'}->{'Users'}->{'User'}[$n]->{'Option'}[1]->{'content'} = $value;
							}
						}
					}
					$xml->XMLout( $data,
								  OutputFile => $Cfg::FileZilla{fz_xml},
								  KeepRoot => 1,
								  NoSort => 0,
								  SuppressEmpty => 0 );

					my @args = ($Cfg::FileZilla{fz_exe}, "/reload-config");
					system(@args);
				}
			}
			return 1;
		}
		elsif( defined($Cfg::Preferences{ftp_method}) && $Cfg::Preferences{ftp_method} eq "PureFTPd")
		{			
			my $uid = `id -u`;
			chomp $uid;
			my $gid = `id -g`;
			chomp $gid;
			
			$login =~ s/('+)/'\"$1\"'/g;
			$password =~ s/('+)/'\"$1\"'/g;
			$home_path =~ s/('+)/'\"$1\"'/g;
			
			if($action eq "list")
			{
				return sudo_exec_without_decrypt("pure-pw list");
			}
			elsif($action eq "userdel")
			{
				return sudo_exec_without_decrypt("pure-pw userdel '$login' && pure-pw mkdb");
			}
			elsif($action eq "useradd")
			{
				return sudo_exec_without_decrypt("(echo '$password'; echo '$password') | pure-pw useradd '$login' -u $uid -g $gid -d '$home_path' && pure-pw mkdb");
			}
			elsif($action eq "passwd")
			{
				return sudo_exec_without_decrypt("(echo '$password'; echo '$password') | pure-pw passwd '$login' && pure-pw mkdb");
			}
			elsif($action eq "show")
			{
				return sudo_exec_without_decrypt("pure-pw show '$login'");
			}
			elsif($action eq "usermod")
			{
				my $update_account = "pure-pw usermod '$login' -u $uid -g $gid";
				
				my @account_settings = split /[\n]+/, $password;
				
				foreach my $setting (@account_settings) {
					my ($key, $value) = split /[\t]+/, $setting;
					
					if( $key eq 'Directory' )
					{
						$value =~ s/('+)/'\"$1\"'/g;
						$update_account .= " -d '$value'";
					}
						
					if( $key eq 'Full_name' )
					{
						if(  $value ne "" )
						{
							$value =~ s/('+)/'\"$1\"'/g;
							$update_account .= " -c '$value'";
						}
						else
						{
							$update_account .= ' -c ""';
						}
					}
					
					if( $key eq 'Download_bandwidth' && $value ne ""  )
					{
						my $Download_bandwidth;
						if($value eq 0)
						{
							$Download_bandwidth = "\"\"";
						}
						else
						{
							$Download_bandwidth = $value;
						}
						$update_account .= " -t " . $Download_bandwidth;
					}
					
					if( $key eq 'Upload___bandwidth' && $value ne "" )
					{
						my $Upload___bandwidth;
						if($value eq 0)
						{
							$Upload___bandwidth = "\"\"";
						}
						else
						{
							$Upload___bandwidth = $value;
						}
						$update_account .= " -T " . $Upload___bandwidth;
					}
					
					if( $key eq 'Max_files' )
					{
						if( $value eq "0" )
						{
							$update_account .= ' -n ""';
						}
						elsif( $value ne "" )
						{
							$update_account .= " -n " . $value;
						}
						else
						{
							$update_account .= ' -n ""';
						}
					}
										
					if( $key eq 'Max_size' )
					{
						if( $value ne "" && $value ne "0" )
						{
							$update_account .= " -N " . $value;
						}
						else
						{
							$update_account .= ' -N ""';
						}
					}
										
					if( $key eq 'Ratio' && $value ne ""  )
					{
						my($upload_ratio,$download_ratio) = split/:/,$value;
						
						if($upload_ratio eq "0")
						{
							$upload_ratio = "\"\"";
						}
						$update_account .= " -q " . $upload_ratio;
						
						if($download_ratio eq "0")
						{
							$download_ratio = "\"\"";
						}
						$update_account .= " -Q " . $download_ratio;
					}
					
					if( $key eq 'Allowed_client_IPs' )
					{
						if( $value ne "" )
						{
							$update_account .= " -r " . $value;
						}
						else
						{
							$update_account .= ' -r ""';
						}
					}
										
					if( $key eq 'Denied__client_IPs' )
					{
						if( $value ne "" )
						{
							$update_account .= " -R " . $value;
						}
						else
						{
							$update_account .= ' -R ""';
						}
					}
					
					if( $key eq 'Allowed_local__IPs' )
					{
						if( $value ne "" )
						{
							$update_account .= " -i " . $value;
						}
						else
						{
							$update_account .= ' -i ""';
						}
					}
										
					if( $key eq 'Denied__local__IPs' )
					{
						if( $value ne "" )
						{
							$update_account .= " -I " . $value;
						}
						else
						{
							$update_account .= ' -I ""';
						}
					}
					
						
					if( $key eq 'Max_sim_sessions' && $value ne "" )
					{
						$update_account .= " -y " . $value;
					}
					
					if ( $key eq 'Time_restrictions'  )
					{
						if( $value eq "0000-0000")
						{
							$update_account .= ' -z ""';
						}
						elsif( $value ne "" )
						{
							$update_account .= " -z " . $value;
						}
						else
						{
							$update_account .= ' -z ""';
						}
					}
				}
				$update_account .=" && pure-pw mkdb";
				# print $update_account;
				return sudo_exec_without_decrypt($update_account);
			}
		}
	}
	return 0;
}

sub start_fastdl
{
	if(-e Path::Class::File->new(FD_DIR, 'Settings.pm'))
	{
		system('CYGWIN="${CYGWIN} nodosfilewarning"; export CYGWIN; perl FastDownload/ForkedDaemon.pm &');
		sleep(1);
		return 1;
	}
	else
	{
		return -2;
	}
}

sub stop_fastdl
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	return stop_fastdl_without_decrypt();
}

sub stop_fastdl_without_decrypt
{
	my $pid;
	open(PIDFILE, '<', FD_PID_FILE)
	  || logger "Error reading pid file $!",1;
	while (<PIDFILE>)
	{
		$pid = $_;
		chomp $pid;
	}
	close(PIDFILE);
	my $cnt = kill 9, $pid;
	if ($cnt == 1)
	{
		logger "Fast Download Daemon Stopped.",1;
		return 1;
	}
	else
	{
		logger "Fast Download Daemon with pid $pid can not be stopped.",1;
		return -1;
	}
}

sub restart_fastdl
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	return restart_fastdl_without_decrypt();
}

sub restart_fastdl_without_decrypt
{
	if((fastdl_status_without_decrypt() == -1) || (stop_fastdl_without_decrypt() == 1))
	{
		if(start_fastdl() == 1)
		{
			# Success
			return 1;
		}
		# Cant start
		return -2;
	}
	# Cant stop
	return -3;
}

sub fastdl_status
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	return fastdl_status_without_decrypt();
}

sub fastdl_status_without_decrypt
{
	my $pid;
	if(!open(PIDFILE, '<', FD_PID_FILE))
	{
		logger "Error reading pid file $!";
		return -1;
	}
	while (<PIDFILE>)
	{
		$pid = $_;
		chomp $pid;
	}
	close(PIDFILE);
	my $cnt = kill 0, $pid;
	if ($cnt == 1)
	{
		return 1;
	}
	else
	{
		return -1;
	}
}

sub fastdl_get_aliases
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my %aliases;
	my $i;
	my @file_lines;
	if(-d FD_ALIASES_DIR)
	{
		if( !opendir(ALIASES, FD_ALIASES_DIR) )
		{
			logger "Error openning aliases directory " . FD_ALIASES_DIR . ", $!";
		}
		else
		{
			while (my $alias = readdir(ALIASES))
			{
				# Skip . and ..
				next if $alias =~ /^\./;
				if( !open(ALIAS, '<', Path::Class::Dir->new(FD_ALIASES_DIR, $alias)) )
				{
					logger "Error reading alias '$alias', $!";
				}
				else
				{
					$i = 0;
					@file_lines = ();
					while (<ALIAS>)
					{
						chomp $_;
						$file_lines[$i] = $_;
						$i++;
					}
					close(ALIAS);
					$aliases{$alias}{home}                  = $file_lines[0];
					$aliases{$alias}{match_file_extension}  = $file_lines[1];
					$aliases{$alias}{match_client_ip}       = $file_lines[2];
				}
			}
			closedir(ALIASES);
		}
	}
	else
	{
		logger "Aliases directory '" . FD_ALIASES_DIR . "' does not exist or is inaccessible.";
	}
	return {%aliases};
}

sub fastdl_del_alias
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	foreach my $alias (decrypt_params(@_))
	{
		unlink Path::Class::File->new(FD_ALIASES_DIR, $alias);
	}
	return restart_fastdl_without_decrypt();
}

sub fastdl_add_alias
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($alias,$home,$match_file_extension,$match_client_ip) = decrypt_params(@_);
	if(!-e FD_ALIASES_DIR)
	{
		if(!mkdir FD_ALIASES_DIR)
		{
			logger "ERROR - Failed to create " . FD_ALIASES_DIR . " directory.";
			return -1;
		}
	}
	my $alias_path = Path::Class::File->new(FD_ALIASES_DIR, $alias);
	if (!open(ALIAS, '>', $alias_path))
	{
		logger "ERROR - Failed to open ".$alias_path." for writing.";
		return -1;
	}
	else
	{
		print ALIAS "$home\n";
		print ALIAS "$match_file_extension\n";
		print ALIAS "$match_client_ip";
		close(ALIAS);
		return restart_fastdl_without_decrypt();
	}
}

sub fastdl_get_info
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	if(-e Path::Class::File->new(FD_DIR, 'Settings.pm'))
	{
		delete $INC{"FastDownload/Settings.pm"};
		require "FastDownload/Settings.pm"; # Settings for Fast Download Daemon.
		if(not defined $FastDownload::Settings{autostart_on_agent_startup})
		{
			$FastDownload::Settings{autostart_on_agent_startup} = 0;
		}
		return {'port'						=>	$FastDownload::Settings{port},
				'ip'						=>	$FastDownload::Settings{ip},
				'listing'					=>	$FastDownload::Settings{listing},
				'autostart_on_agent_startup'=>	$FastDownload::Settings{autostart_on_agent_startup}};
	}
	return -1
}

sub fastdl_create_config
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	if(!-e FD_DIR)
	{
		if(!mkdir FD_DIR)
		{
			logger "ERROR - Failed to create " . FD_DIR . " directory.";
			return -1;
		}
	}
	my ($fd_address, $fd_port, $listing, $autostart_on_agent_startup) = decrypt_params(@_);
	my $settings_string = "%FastDownload::Settings = (\n".
						  "\tport  => $fd_port,\n".
						  "\tip => '$fd_address',\n".
						  "\tlisting => $listing,\n".
						  "\tautostart_on_agent_startup => $autostart_on_agent_startup,\n".
						  ");";
	my $settings = Path::Class::File->new(FD_DIR, 'Settings.pm');
	if (!open(SETTINGS, '>', $settings))
	{
		logger "ERROR - Failed to open $settings for writing.";
		return -1;
	}
	else
	{
		print SETTINGS $settings_string;
		close(SETTINGS);
	}
	logger "$settings file written successfully.";
	return 1;
}

sub agent_restart
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my $dec_check = decrypt_param(@_);
	if ($dec_check eq 'restart')
	{
		chdir AGENT_RUN_DIR;
		if(-e "ogp_agent_run.pid")
		{
			my $init_pid	= `cat ogp_agent_run.pid`;
			chomp($init_pid);
			
			if(kill 0, $init_pid)
			{
				my $or_exist	= "";
				my $rm_pid_file	= "";
				my $agent_pid = "";
				my $restart_scr_log = Path::Class::File->new(SCREEN_LOGS_DIR, 'screenlog.agent_restart');
				my $agent_scr_log = Path::Class::File->new(SCREEN_LOGS_DIR, 'screenlog.ogp_agent');
				
				if(-e $restart_scr_log)
				{
					unlink $restart_scr_log;
				}
				
				if(-e $agent_scr_log)
				{
					unlink $agent_scr_log;
				}
				
				if(-e "ogp_agent.pid")
				{
					$rm_pid_file .= " ogp_agent.pid";
					$agent_pid = `cat ogp_agent.pid`;
					chomp($agent_pid);
					if( kill 0, $agent_pid )
					{
						$or_exist .= " -o -e /proc/$agent_pid";
					}
				}
				
				my $pureftpd_pid = "";
				if(-e "/var/run/pure-ftpd.pid")
				{
					$rm_pid_file .= " /var/run/pure-ftpd.pid";
					$pureftpd_pid = `cat /var/run/pure-ftpd.pid`;
					chomp($pureftpd_pid);
					if( kill 0, $pureftpd_pid )
					{
						$or_exist .= " -o -e /proc/$pureftpd_pid";
					}
				}
				
				open (AGENT_RESTART_SCRIPT, '>', 'tmp_restart.sh');
				my $restart = "echo -n \"Stopping OGP Agent...\"\n".
							  "kill $init_pid $agent_pid $pureftpd_pid\n".
							  "while [ -e /proc/$init_pid $or_exist ];do echo -n .;sleep 1;done\n".
							  "rm -f $rm_pid_file\necho \" [OK]\"\n".
							  "echo -n \"Starting OGP Agent...\"\n".
							  "screen -d -m -t \"ogp_agent\" -c \"" . SCREENRC_FILE . "\" -S ogp_agent bash ogp_agent -pidfile /OGP/ogp_agent_run.pid\n".
							  "while [ ! -e 'ogp_agent.pid' ];do echo -n .;sleep 1;done\n".
							  "echo \" [OK]\"\n".
							  "rm -f tmp_restart.sh\n".
							  "exit 0\n";
				print AGENT_RESTART_SCRIPT $restart;
				close (AGENT_RESTART_SCRIPT);
				if( -e 'tmp_restart.sh' )
				{
					system('screen -d -m -t "agent_restart" -c "' . SCREENRC_FILE . '" -S agent_restart bash tmp_restart.sh');
				}
			}
		}
	}
	return -1;
}

# Subroutines to be called
sub scheduler_dispatcher {
	my ($task, $args) = @_;
	my $response = `$args`;
	chomp($response);
	my $log = "Executed command: $args";
	if($response ne "")
	{
		$log .= ", response:\n$response";
	}
	scheduler_log_events($log);
}

sub scheduler_server_action
{
	my ($task, $args) = @_;
	my ($action, @server_args) = split('\|\%\|', $args);
	if($action eq "%ACTION=start")
	{
		my ($home_id, $ip, $port) = ($server_args[0], $server_args[6], $server_args[5]);
		my $ret = universal_start_without_decrypt(@server_args);
		if($ret == 1)
		{
			scheduler_log_events("Started server home ID $home_id on address $ip:$port");
		}
		else
		{
			scheduler_log_events("Failed starting server home ID $home_id on address $ip:$port (Check agent log)");
		}
	}
	elsif($action eq "%ACTION=stop")
	{
		my ($home_id, $ip, $port) = ($server_args[0], $server_args[1], $server_args[2]);
		my $ret = stop_server_without_decrypt(@server_args);
		if($ret == 0)
		{
			scheduler_log_events("Stopped server home ID $home_id on address $ip:$port");
		}
		elsif($ret == 1)
		{
			scheduler_log_events("Failed stopping server home ID $home_id on address $ip:$port (Invalid IP:Port given)");
		}
	}
	elsif($action eq "%ACTION=restart")
	{
		my ($home_id, $ip, $port) = ($server_args[0], $server_args[1], $server_args[2]);
		my $ret = restart_server_without_decrypt(@server_args);
		if($ret == 1)
		{
			scheduler_log_events("Restarted server home ID $home_id on address $ip:$port");
		}
		elsif($ret == -1)
		{
			scheduler_log_events("Failed restarting server home ID $home_id on address $ip:$port (Server could not be started, check agent log)");
		}
		elsif($ret == -2)
		{
			scheduler_log_events("Failed restarting server home ID $home_id on address $ip:$port (Server could not be stopped, check agent log)");
		}
	}
	return 1;
}

sub scheduler_log_events
{
	my $logcmd	 = $_[0];
	$logcmd = localtime() . " $logcmd\n";
	logger "Can't open " . SCHED_LOG_FILE . " - $!" unless open(LOGFILE, '>>', SCHED_LOG_FILE);
	logger "Failed to lock " . SCHED_LOG_FILE . "." unless flock(LOGFILE, LOCK_EX);
	logger "Failed to seek to end of " . SCHED_LOG_FILE . "." unless seek(LOGFILE, 0, 2);
	logger "Failed to write to " . SCHED_LOG_FILE . "." unless print LOGFILE "$logcmd";
	logger "Failed to unlock " . SCHED_LOG_FILE . "." unless flock(LOGFILE, LOCK_UN);
	logger "Failed to close " . SCHED_LOG_FILE . "." unless close(LOGFILE);
}

sub scheduler_add_task
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my $new_task = decrypt_param(@_);
	if (open(TASKS, '>>', SCHED_TASKS))
	{
		print TASKS "$new_task\n";
		logger "Created new task: $new_task";
		close(TASKS);
		scheduler_stop();	
		# Create new object with default dispatcher for scheduled tasks
		$cron = new Schedule::Cron( \&scheduler_dispatcher, {
												nofork => 1,
												loglevel => 0,
												log => sub { print $_[1], "\n"; }
											   } );

		$cron->add_entry( "* * * * * *", \&scheduler_read_tasks );
		# Run scheduler
		$cron->run( {detach=>1, pid_file=>SCHED_PID} );
		return 1;
	}
	logger "Cannot create task: $new_task ( $! )";
	return -1;
}

sub scheduler_del_task
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my $name = decrypt_param(@_);
	if( scheduler_read_tasks() == -1 )
	{
		return -1;
	}
	my @entries = $cron->list_entries();
	if(open(TASKS, '>', SCHED_TASKS))
	{
		foreach my $task ( @entries ) {
			next if $task->{args}[0] eq $name;
			next unless $task->{args}[0] =~ /task_[0-9]*/;
			if(defined $task->{args}[1])
			{
				print TASKS join(" ", $task->{time}, $task->{args}[1]) . "\n";
			}
			else
			{
				print TASKS $task->{time} . "\n";
			}
		}
		close( TASKS );
		scheduler_stop();
		# Create new object with default dispatcher for scheduled tasks
		$cron = new Schedule::Cron( \&scheduler_dispatcher, {
												nofork => 1,
												loglevel => 0,
												log => sub { print $_[1], "\n"; }
											   } );

		$cron->add_entry( "* * * * * *", \&scheduler_read_tasks );
		# Run scheduler
		$cron->run( {detach=>1, pid_file=>SCHED_PID} );
		return 1;
	}
	logger "Cannot open file " . SCHED_TASKS . " for deleting task id: $name ( $! )",1;
	return -1;
}

sub scheduler_edit_task
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($name, $new_task) = decrypt_params(@_);
	if( scheduler_read_tasks() == -1 )
	{
		return -1;
	}
	my @entries = $cron->list_entries();
	if(open(TASKS, '>', SCHED_TASKS))
	{
		foreach my $task ( @entries ) {
			next unless $task->{args}[0] =~ /task_[0-9]*/;
			if($name eq $task->{args}[0])
			{
				print TASKS "$new_task\n";
			}
			else
			{
				if(defined $task->{args}[1])
				{
					print TASKS join(" ", $task->{time}, $task->{args}[1]) . "\n";
				}
				else
				{
					print TASKS $task->{time} . "\n";
				}
			}
		}
		close( TASKS );
		scheduler_stop();
		# Create new object with default dispatcher for scheduled tasks
		$cron = new Schedule::Cron( \&scheduler_dispatcher, {
												nofork => 1,
												loglevel => 0,
												log => sub { print $_[1], "\n"; }
											   } );

		$cron->add_entry( "* * * * * *", \&scheduler_read_tasks );
		# Run scheduler
		$cron->run( {detach=>1, pid_file=>SCHED_PID} );
		return 1;
	}
	logger "Cannot open file " . SCHED_TASKS . " for editing task id: $name ( $! )",1;
	return -1;
}

sub scheduler_read_tasks
{
	if( open(TASKS, '<', SCHED_TASKS) )
	{
		$cron->clean_timetable();
	}
	else
	{
		logger "Error reading tasks file $!";
		scheduler_stop();
		return -1;
	}
	
	my $i = 0;
	while (<TASKS>)
	{	
		next if $_ =~ /^(#.*|[\s|\t]*?\n)/;
		my ($minute, $hour, $dayOfTheMonth, $month, $dayOfTheWeek, @args) = split(' ', $_);
		my $time = "$minute $hour $dayOfTheMonth $month $dayOfTheWeek";
		if("@args" =~ /^\%ACTION.*/)
		{
			$cron->add_entry($time, \&scheduler_server_action, 'task_' . $i++, "@args");
		}
		else
		{
			$cron->add_entry($time, 'task_' . $i++, "@args");
		}
	}
	close(TASKS);
	return 1;
}

sub scheduler_stop
{
	my $pid;
	if(open(PIDFILE, '<', SCHED_PID))
	{
		$pid = <PIDFILE>;
		chomp $pid;
		close(PIDFILE);
		if($pid ne "")
		{
			if( kill 0, $pid )
			{
				my $cnt = kill 9, $pid;
				if ($cnt == 1)
				{
					unlink SCHED_PID;
					return 1;
				}
			}
		}
	}
	return -1;
}

sub scheduler_list_tasks
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	if( scheduler_read_tasks() == -1 )
	{
		return -1;
	}
	my @entries = $cron->list_entries();
	my %entries_array;
	foreach my $task ( @entries ) {
		if( defined $task->{args}[1] )
		{
			$entries_array{$task->{args}[0]} = encode_base64(join(" ", $task->{time}, $task->{args}[1]));
		}
		else
		{
			$entries_array{$task->{args}[0]} = encode_base64($task->{time});
		}
	}
	if( %entries_array )
	{
		return {%entries_array};
	}
	return -1;
}

sub get_file_part
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($file, $offset) = decrypt_params(@_);
	if (!open(FILE, '<', $file))
	{
		logger "ERROR - Can't open file $file for reading.";
		return -1;
	}
	
	binmode(FILE);
	
	if($offset != 0)  
	{
		return -1 unless seek FILE, $offset, 0;
	}
	
	my $data = "";
	my ($n, $buf);
	my $limit = $offset + 60 * 57 * 1000; #Max 3420Kb (1000 iterations) (top statistics ~ VIRT 116m, RES 47m)
	while (($n = read FILE, $buf, 60 * 57) != 0 && $offset <= $limit ) {
		$data .= $buf;
		$offset += $n;
	}
	close(FILE);
	
    if( $data ne "" )
	{
		my $b64zlib = encode_base64(compress($data,9));
		return "$offset;$b64zlib";
	}
	else
	{
		return -1;
	}
}

sub stop_update
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my $home_id = decrypt_param(@_);
	my $screen_id = create_screen_id(SCREEN_TYPE_UPDATE, $home_id);
	system('screen -S '.$screen_id.' -p 0 -X stuff $\'\003\'');
	if ($? == 0)
	{
		return 0;
	}
	return 1
}

sub shell_action
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($action, $arguments) = decrypt_params(@_);
	
	if($action eq 'remove_file')
	{
		chomp($arguments);
		unlink($arguments);
		return "1;";
	}
	elsif($action eq 'remove_recursive')
	{
		my @items = split(';', $arguments);
		foreach my $item ( @items ) {
			chomp($item);
			if(-d $item)
			{
				pathrmdir($item);
			}
			else
			{
				unlink($item);
			}
		}
		return "1;";
	}
	elsif($action eq 'create_dir')
	{
		chomp($arguments);
		mkpath($arguments);
		return "1;";
	}
	elsif($action eq 'move')
	{
		my($src, $dest) = split(';', $arguments);
		chomp($src);
		chomp($dest);
		if(-d $src)
		{
			$dest = Path::Class::Dir->new($dest, basename($src));
			dirmove($src, $dest);
		}
		else
		{
			fmove($src, $dest);
		}
		return "1;";
	}
	elsif($action eq 'copy')
	{
		my($src, $dest) = split(';', $arguments);
		chomp($src);
		chomp($dest);
		if(-d $src)
		{
			$dest = Path::Class::Dir->new($dest, basename($src));
			dircopy($src, $dest);
		}
		else
		{
			fcopy($src, $dest);
		}
		return "1;";
	}
	elsif($action eq 'touch')
	{
		chomp($arguments);
		open(FH, '>', $arguments);
		print FH "";
		close(FH);
		return "1;";
	}
	elsif($action eq 'size')
	{
		chomp($arguments);
		my $size = 0;
		if(-d $arguments)
		{
			find(sub { $size += -s }, $arguments ? $arguments : '.');
		}
		else
		{
			$size += (stat($arguments))[7];
		}
		return "1;" . encode_list($size);
	}
	elsif($action eq 'get_cpu_usage')
	{
		my %prev_idle;
		my %prev_total;
		open(STAT, '/proc/stat');
		while (<STAT>) {
			next unless /^cpu([0-9]+)/;
			my @stat = split /\s+/, $_;
			$prev_idle{$1} = $stat[4];
			$prev_total{$1} = $stat[1] + $stat[2] + $stat[3] + $stat[4];
		}
		close STAT;
		sleep 1;
		my %idle;
		my %total;
		open(STAT, '/proc/stat');
		while (<STAT>) {
			next unless /^cpu([0-9]+)/;
			my @stat = split /\s+/, $_;
			$idle{$1} = $stat[4];
			$total{$1} = $stat[1] + $stat[2] + $stat[3] + $stat[4];
		}
		close STAT;
		my %cpu_percent_usage;
		foreach my $key ( keys %idle )
		{
			my $diff_idle = $idle{$key} - $prev_idle{$key};
			my $diff_total = $total{$key} - $prev_total{$key};
			my $percent = (100 * ($diff_total - $diff_idle)) / $diff_total;
			$percent = sprintf "%.2f", $percent unless $percent == 0;
			$cpu_percent_usage{$key} = encode_base64($percent);
		}
		return {%cpu_percent_usage};
	}
	elsif($action eq 'get_ram_usage')
	{
		my($total, $buffers, $cached, $free) = qw(0 0 0 0);
		open(STAT, '/proc/meminfo');
		while (<STAT>) {
			$total   += $1 if /MemTotal\:\s+(\d+) kB/;
			$buffers += $1 if /Buffers\:\s+(\d+) kB/;
			$cached  += $1 if /Cached\:\s+(\d+) kB/;
			$free    += $1 if /MemFree\:\s+(\d+) kB/;
		}
		close STAT;
		my $used = $total - $free - $cached - $buffers;
		my $percent = 100 * $used / $total;
		my %mem_usage;
		$mem_usage{'used'}    = encode_base64($used * 1024);
		$mem_usage{'total'}   = encode_base64($total * 1024);
		$mem_usage{'percent'} = encode_base64($percent);
		return {%mem_usage};
	}
	elsif($action eq 'get_disk_usage')
	{
		my($total, $used, $free) = split(' ', `df -lP 2>/dev/null|grep "^.:\\s"|awk '{total+=\$2}{used+=\$3}{free+=\$4} END {print total, used, free}'`);
		my $percent = 100 * $used / $total;
		my %disk_usage;
		$disk_usage{'free'}    = encode_base64($free * 1024);
		$disk_usage{'used'}    = encode_base64($used * 1024);
		$disk_usage{'total'}   = encode_base64($total * 1024);
		$disk_usage{'percent'} = encode_base64($percent);
		return {%disk_usage};
	}
	elsif($action eq 'get_uptime')
	{
		open(STAT, '/proc/uptime');
		my $uptime = 0;
		while (<STAT>) {
			$uptime += $1 if /^([0-9]+)/;
		}
		close STAT;
		my %upsince;
		$upsince{'0'} = encode_base64($uptime);
		$upsince{'1'} = encode_base64(time - $uptime);
		return {%upsince};
	}
	elsif($action eq 'get_tasklist')
	{
		my %taskList;
		$taskList{'task'} = encode_base64(`tasklist /fo TABLE`);
		return {%taskList};
	}
	elsif($action eq 'get_timestamp')
	{
		return "1;" . encode_list(time);
	}
	return 0;
}

sub remote_query
{
	return "Bad Encryption Key" unless(decrypt_param(pop(@_)) eq "Encryption checking OK");
	my ($protocol, $game_type, $ip, $c_port, $q_port, $s_port) = decrypt_params(@_);
	my $PHP_CGI = system('which php-cgi >/dev/null 2>&1');
	if ($PHP_CGI eq 0)
	{
		$PHP_CGI = `which php-cgi`;
		chomp($PHP_CGI);
	}
	else
	{
		return -1;
	}
	my $php_query_dir = Path::Class::Dir->new(AGENT_RUN_DIR, 'php-query');
	if($protocol eq 'lgsl')
	{
		chdir($php_query_dir->subdir('lgsl'));
		my $cmd = $PHP_CGI .
				" -f lgsl_feed.php" .
				" lgsl_type=" . $game_type . 
				" ip=" . $ip .
				" c_port=" . $c_port .
				" q_port=" . $q_port .
				" s_port=" . $s_port .
				" request=sp";
		my $response = `$cmd`;
		chomp($response);
		chdir(AGENT_RUN_DIR);
		if($response eq "FAILURE")
		{
			return -1;
		}
		return encode_base64($response, "");
	}
	elsif($protocol eq 'gameq')
	{
		chdir($php_query_dir->subdir('gameq'));
		my $cmd = $PHP_CGI .
				" -f gameq_feed.php" .
				" game_type=" . $game_type . 
				" ip=" . $ip .
				" c_port=" . $c_port .
				" q_port=" . $q_port .
				" s_port=" . $s_port;
		my $response = `$cmd`;
		chomp($response);
		chdir(AGENT_RUN_DIR);
		if($response eq "FAILURE")
		{
			return -1;
		}
		return encode_base64($response, "");
	}
	return -1;
}