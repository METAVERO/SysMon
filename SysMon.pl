#TODO put this is the configuration file
#Update below variables in email notification function
#my $MAIL_SERVER='smtp.myco.com';
#my $BATCH_USER='Hyperion_Mon@myco.com';

use strict;
use File::stat;
use IO::Socket;
use LWP::UserAgent;
use HTTP::Request::Common;
use HTTP::Cookies;
use URI::Escape;
use Net::SMTP;

my $user_id;
my $password;
my $logon_raf;
my @Machines=();
my @OPSEmailNotify=();
my %LoggedErrors;
my %ApplicationCheck;
my %Downtime;
my %ErrorAction;
my %Logs;
my %Ports;
my %Service;

#DB Outage window Saturdays from 9:00 PM - 11:30

my $service_message="";
my $service_timestamp="";
#ORA-01033: ORACLE initialization or shutdown in progress
my %day_hash = ('SUN',0,'MON',1,'TUE',2,'WED',3,'THU',4,'FRI',5,'SAT',6);

my($filepath,$junk) = split(/\./,$0);
my $config_file=$filepath.".cfg";
print "Reading $config_file\n";
open (CONFIG_FILE,$config_file) || die "cannot open file $config_file\n";

my @lines = <CONFIG_FILE>;
close(CONFIG_FILE);

my $index;
my $type;
my $id;
my $type_attrib;
my $count = @lines;
print "Found $count lines in ".$config_file."\n";
for ($index = 0;$index< $count;$index++) {
if (!($lines[$index] =~m/^\#/)) {
	($type,$id,$type_attrib)=split(/,/,$lines[$index]);
	chomp $type_attrib;

	if ($type eq  "error_action") {$ErrorAction{ $id } = $type_attrib; goto END_SWITCH}				
	if ($type eq  "down_time") {$Downtime{ $id } = $type_attrib; goto END_SWITCH}
	if ($type eq  "log") {$Logs{ $id } = $type_attrib; goto END_SWITCH}
	if ($type eq  "service") {$Service{ $id } = $type_attrib; goto END_SWITCH}
	if ($type eq  "port") { $Ports{ $id } = $type_attrib; goto END_SWITCH}				
	if ($type eq  "appcheck") {$ApplicationCheck{ $id } = $type_attrib; goto END_SWITCH}			
	if ($type eq  "machine") {push(@Machines,"$id,$type_attrib"); goto END_SWITCH}
	if ($type eq  "email") {if ($id eq "OPS") {push(@OPSEmailNotify,"$type_attrib");} goto END_SWITCH}
	if ($type eq  "credentials") { $user_id = $id; $password = $type_attrib; goto END_SWITCH}
	print "unknown type $type, ignoring\n";
	END_SWITCH:
	}			
}


my $ERROR_FH;
my $error_file=$filepath.".err";

if (-f $error_file) {
	open ($ERROR_FH,"<", $error_file) || die "cannot open file $error_file\n";
	while (<$ERROR_FH>) {
		chomp $_;
		my($ts,$app,$log)=split(/_/);		
		$LoggedErrors{ $app.$ts } = $log;		
	}
	close $ERROR_FH;
}

open ($ERROR_FH,">", $error_file) || die "cannot open file $error_file\n";

#Loop through down-time and perform checks if we are not in down_time window
if (downtime_check("ALL")) { print("Down time window, no system checks shall be ran.\n"); }
else {
	application_check($ERROR_FH);
	monitor_logs($ERROR_FH);
}

close $ERROR_FH;

sub application_check() {
my $FH = shift @_;
my $error_message="";
my $ts=localtime;

foreach (@Machines) {
my($service_id,$machine_name)=split(/,/);

if (downtime_check($service_id)==0) {
	if ($ApplicationCheck{$service_id}  eq "port") 
		{ if (port_check($machine_name,$service_id)) {printf $FH "%s_%s_%s\n",$machine_name,$Ports{$service_id},$ts;
		  if (!exists($LoggedErrors{$Ports{$service_id}.$machine_name}))  { $error_message=$error_message."Machine Name: $machine_name Service:$Service{$service_id} Port:$Ports{$service_id} not available\n"}} 
		   goto END_APP_CHECK;
		}
		
	if ($ApplicationCheck{$service_id}  eq "loginwks")
		{ 
		$logon_raf = logon_raf_smartview($machine_name,"IIS",$user_id,$password);
		if ($logon_raf==1) { printf $FH "%s_%s_%s\n",$machine_name,"loginwks",$ts; if (!exists($LoggedErrors{"loginwks".$machine_name}))  {$error_message=$error_message."logon_raf_smartview: $machine_name Invalid User or Password passed to login_raf_smartview!"; }} 
		if ($logon_raf==2) { printf $FH "%s_%s_%s\n",$machine_name,"loginwks",$ts; if (!exists($LoggedErrors{"loginwks".$machine_name}))  {$error_message=$error_message."logon_raf_smartview: $machine_name Service:".$Service{'SSWEB'}." FAILED\n";}}
		if ($logon_raf==3) { printf $FH "%s_%s_%s\n",$machine_name,"loginwks",$ts; if (!exists($LoggedErrors{"loginwks".$machine_name}))  {$error_message=$error_message."logon_raf_smartview: $machine_name Service:".$Service{'RAFWEB'}." FAILED\n";}}
		if ($logon_raf==4) { printf $FH "%s_%s_%s\n",$machine_name,"loginwks",$ts; if (!exists($LoggedErrors{"loginwks".$machine_name}))  {$error_message=$error_message."logon_raf_smartview: $machine_name Service:".$Service{'RAFAGENT'}." FAILED\n";}}
		goto END_APP_CHECK;
		}
		print "No application check found for type $service_id\n";
	END_APP_CHECK:
	
}
}
if (length($error_message)>0) { email_alert("Hyperion Log Alert",$error_message,\@OPSEmailNotify);}
}

sub restart_service {
my $computer_name=shift @_;
my $service_name=shift @_;
system("sc stop $service_name");
sleep(30);
system("sc start $service_name");
}

sub port_check () {
my $machine_name=shift @_;
my $service_id=shift @_;

my $sock = new IO::Socket::INET (
                                  PeerAddr => $machine_name,
                                  PeerPort => $Ports{$service_id},
                                  Proto => 'tcp',
								  Timeout => '2',
                                );
if ($sock) { close($sock); return 0; }
else { return 1;}
}

sub monitor_logs {
my $FH = shift @_;
my $ts;
my $error_message="";

print "Monitor Logs\n";

while ( my ($app_id, $log_path) = each(%Logs) ) {
if (-f $log_path) {
	open (FILE, "< $log_path") or die("Cannot open input file $log_path\n");	
	while (<FILE>) {		
	if (substr($_, 0, 1) eq "<")  {	
	$service_message=$_;
	my $junk;
	($ts,$junk)=split(/\>/);
	($junk,$ts)=split(/\</,$ts);	
	}
	else {
	$service_message.=$_;
	}	
	while ( my ($message, $action) = each(%ErrorAction) ) {		
		if ($_ =~ m/$message/i) {				
		    printf $FH "%s_%s_%s\n",$ts,$app_id,$log_path;			
			if (!exists($LoggedErrors{$app_id.$ts}))  {				
				$error_message = $error_message."Service ID: $app_id Service Name: $Service{$app_id}\n$service_message\n\n";
#				switch ($action) {
#					case "restart_notify" {print "Zip of logs, Restart Services and Notify\nMachine Name: $ENV{COMPUTERNAME} Service ID: $app_id Service Name: $Service{$app_id}\n$service_message"}
#					case "notify" {print "Notify, Machine Name: $ENV{COMPUTERNAME} Service ID: $app_id Service Name: $Service{$app_id}\n$service_message"}
#					else { print "default\n"};
#				}
			}
		}
	}
	

	}
	close FILE;
}
else {
print "File not found $log_path\n";
}
}
if (length($error_message)>0) { email_alert("Hyperion Log Alert",$error_message,\@OPSEmailNotify);}
}

sub logon_raf_smartview() {
my $SERVER=shift;
my $WEBSERVER=shift;
my $USER=shift;
my $PASSWORD=shift;
my $CLIENT_VERSION="4.2.0.0.0";
my $SERVER_PORT;

if ($WEBSERVER !~ m/IIS/) {	$SERVER_PORT=$SERVER.":19000"; }
else {$SERVER_PORT=$SERVER;}

my $userAgent = LWP::UserAgent->new(agent => 'HttpApp/1.0');

# Store Cookies
$userAgent->cookie_jar(
        HTTP::Cookies->new(
            file => 'mycookies.txt',
            autosave => 1
        )
    );

my $message = "<req_ConnectToProvider><ClientXMLVersion>".$CLIENT_VERSION."</ClientXMLVersion><lngs enc=\"0\">en_US</lngs><usr></usr><pwd></pwd></req_ConnectToProvider>";
my $response = $userAgent->request(POST 'http://'.$SERVER_PORT.'/workspace/SmartViewProviders',
Content_Type => 'text/xml',
Content => $message);

if (!$response->is_success || $response->as_string !~ m/Oracle Enterprise Performance Management System Workspace/) {
print("login_raf_smartview: Failed to receive workspace response from $SERVER_PORT, check Hyperion Foundation Services - Managed Server\n");
return 2;
}

my $message = "<req_GetProvisionedDataSources><usr></usr><pwd></pwd><filters></filters></req_GetProvisionedDataSources>";
my $response = $userAgent->request(POST 'http://'.$SERVER_PORT.'/workspace/SmartViewProviders',
Content_Type => 'text/xml',
Content => $message);

if (!$response->is_success || $response->as_string !~ m/User authentication needed/) {
print("login_raf_smartview: Failed to receive workspace authentication challenge from $SERVER_PORT, check Hyperion Foundation Services - Managed Server\n");
return 2;
}

my $message = "<req_GetProvisionedDataSources><usr>".$USER."</usr><pwd>".$PASSWORD."</pwd><filters></filters></req_GetProvisionedDataSources>";
my $response = $userAgent->request(POST 'http://'.$SERVER_PORT.'/workspace/SmartViewProviders',
Content_Type => 'text/xml',
Content => $message);

if ($response->is_success && $response->as_string =~ m/Invalid login/) {
print("login_raf_smartview: Invalid username or password passed to login_raf_smartview function in monitoring script\n");
return 1;
}

if (!$response->is_success || $response->as_string !~ m/\<sso\>/) {
print("login_raf_smartview: Failed to receive sso token from $SERVER_PORT, check Hyperion Foundation Services - Managed Server\n");
return 2;
}

my $sso_token = substr($response->as_string,index($response->as_string,"<sso>")+5,index($response->as_string,"</sso>")-index($response->as_string,"<sso>")-5);

$message="<req_GetProvisionedDataSources><sso>".$sso_token."</sso><filters></filters></req_GetProvisionedDataSources>";
my $response = $userAgent->request(POST 'http://'.$SERVER_PORT.'/workspace/SmartViewProviders',
Content_Type => 'text/xml',
Content => $message);

if (!$response->is_success || $response->as_string !~ m/res_GetProvisionedDataSources/) {
print("login_raf_smartview: Failed to receive response to GetProvisionedDataSources request from $SERVER_PORT, check Hyperion Foundation Services - Managed Server\n");
return 2;
}

my $message = "rcp_version=1.4&sso_token=".uri_escape($sso_token)."&applicationtype=officeAddin&applicationversion=1.0.0&format=excel.2003&hycmnaddin18467=41&action=server";
my $response = $userAgent->request(POST 'http://'.$SERVER_PORT.'/raframework/browse/listXML',
Content_Type => 'application/x-www-form-urlencoded;charset=UTF-8',
Content => $message);

if (!$response->is_success && $response->as_string =~ m/Service Unavailable/) {
print("login_raf_smartview: Failed to conect to $SERVER_PORT.  Check Hyperion Reporting and Analysis Framework Web Application\n");
return 3;
}

if ($response->is_success && $response->as_string =~ m/port 6800/) {
print("login_raf_smartview: Failed to conect.  Server cannot connect to port 6800, check Hyperion Reporting Analysis Framework\n");
return 4;
}

print("login_raf_smartview: passed for $SERVER_PORT\n");
return 0;
}

sub downtime_check() {
my $service_id=shift @_;

my $system_downtime=0;
my ($seconds,$minute,$hour,$day,$month,$year,$wday,$yday,$isdst)=localtime(time);
my $hourmin=$hour*100 + $minute;

if (exists($Downtime{$service_id}))  {
	my($dow,$start_time,$end_time)=split(/_/,$Downtime{$service_id});
	if ( (uc($dow) eq "ALL" || $day_hash{uc($dow)} == $wday)&& $hourmin>=$start_time && $hourmin<=$end_time) { return 1;}
}
return 0;
}

sub email_alert {
my $SUBJ=shift;
my $MESSAGE=shift;
my $NOTIFY_USER_ARRAY=shift;

my $MAIL_SERVER='smtp.myco.com';
my $BATCH_USER='Hyperion_Mon@myco.com';

my $mailto;

my $smtp = Net::SMTP->new($MAIL_SERVER);
print $smtp->banner();
$smtp->mail($BATCH_USER);

print $smtp->code();
print $smtp->message();

$smtp->recipient(@$NOTIFY_USER_ARRAY);

print $smtp->code();
print $smtp->message();

$smtp->data();
foreach $mailto (@$NOTIFY_USER_ARRAY) {
print "Notifying $mailto \n";
$smtp->datasend("To: $mailto\n");
}
$smtp->datasend("Subject: $ENV{COMPUTERNAME} - $SUBJ\n\n");
$smtp->datasend("\n");
$smtp->datasend("$MESSAGE\n");
$smtp->dataend();

print $smtp->code();
print $smtp->message();

$smtp->quit;
}