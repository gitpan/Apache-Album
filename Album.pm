package Apache::Album;

# For detailed information on this module, please see
# the pod data at the bottom of this file
#
# Copyright 1998-1999 James D Woodgate.  All rights reserved.
# It may be used and modified freely, but I do request that this copyright
# notice remain attached to the file.  You may modify this module as you 
# wish, but if you redistribute a modified version, please attach a note
# listing the modifications you have made.

use Image::Magick;
use strict;
use vars qw($VERSION);
use Apache::Constants qw/:common REDIRECT/;
use Apache::Request;

$VERSION = '0.92';

sub handler {
  my $r = Apache::Request->new(shift);
  
  # All the configurable values will be stored in %settings

  my %settings;
  
  $settings{'AlbumDir'} = 
    $r->dir_config('AlbumDir')            || "/albums_loc";
  $settings{'ThumbNailUse'} = 
    lc($r->dir_config('ThumbNailUse'))    || "width";
  $settings{'ThumbNailWidth'} = 
    $r->dir_config('ThumbNailWidth')      || 100;
  $settings{'ThumbNailAspect'}  = 
    $r->dir_config('ThumbNailAspect')     || "1/5";
  $settings{'ThumbSubDir'} =
    $r->dir_config('ThumbSubDir')         || 'thumbs';
  $settings{'DefaultBrowserWidth'} = 
    $r->dir_config('DefaultBrowserWidth') || 640;
  $settings{'BodyArgs'} = 
    $r->dir_config('BodyArgs');
  $settings{'OutsideTableBorder'} = 
    $r->dir_config('OutsideTableBorder')  || 0;
  $settings{'InsideTablesBorder'} = 
    $r->dir_config('InsideTablesBorder')  || 0;
  $settings{'Footer'} = 
    $r->dir_config('Footer');
  $settings{'EditMode'} =
    $r->dir_config('EditMode') || 0;
  $settings{'AllowFinalResize'} =
    $r->dir_config('AllowFinalResize') || 0;
  $settings{'FinalResizeDir'} =
    $r->dir_config('FinalResizeDir') || $r->dir_config('ThumbSubDir');
  $settings{'ReverseDirs'} =
    $r->dir_config('ReverseDirs') || 0;
  $settings{'ReversePics'} = 
    $r->dir_config('ReversePics') || 0;
  
  # Set up $album_uri and $album_dir, _uri for web access, _dir
  # for physical access to the files...
  my $album_uri = $settings{'AlbumDir'};
  $album_uri .= "/" unless substr($album_uri,-1,1) eq '/';
  my $album_dir = $r->lookup_uri($album_uri)->filename;
  chop $album_uri;  # Won't need that '/' any more

  # Check and see if there was a post
  my %params = ();
  if ($settings{'EditMode'}) {
    %params = $r->method eq 'POST' ? $r->content : $r->args;

#    foreach (keys %params) {
#      $r->log_error("$_ -> $params{$_}");
#    }

    if (defined $params{'AlbumName'}) {
      my $directory = $params{AlbumName};
      $directory =~ s,[^\w\d()],,g;
      my $local_path_info = $r->path_info;
      if ($directory eq "") {
	$r->log_error("Directory empty (or only consists of bad characters)");
      }
      else {
	$r->warn("Creating New Album: $directory under $local_path_info");
	mkdir("$album_dir$local_path_info$directory", 0755);
      }
    }
    else {
      unless ($params{'New Album'}) {
	if (my $handle = $r->upload('filename')) {
	  my $filename = $handle->filename;
	  my ($type,$ext) = split(/\//,$handle->info("Content-type"));

	  if ($type eq 'image') {
	    # on NT $filename has \'s which we don't want!
	    $filename =~ s,.*\\,,;

	    $r->warn("Uploading: $filename");
	    my $local_path_info = $r->path_info;
	    my $fh = $handle->fh;

	    if(open(OUT,">$album_dir$local_path_info$filename")) {
	      while(<$fh>) {
		print OUT;
	      }
	      
	      close OUT;
	    }
	    else {
	      $r->log_error("Problem opening $album_dir$local_path_info$filename for write: $!");
	    }
	  }
	  else {
	    $r->log_error("Will not allow upload of: $filename $type/$ext");
	  }
	}
      }
    }
  }

  # path_info will be the sub directory/possible file_name
  # get rid of any slashes so we can make sure that paths
  # look like paths
  my $path_info = $r->path_info;
  $path_info =~ s!^/+!!;
  $path_info =~ s!/+$!!;
  $path_info || return &show_albums($r, $album_dir, $path_info, \%settings);
  
  # do we have a directory or a filename, if it's a filename
  # simply load it up
  if ( -f "$album_dir/$path_info" ) {
    return &show_picture($r, $album_uri, $path_info, \%settings);
  }

  # if AllowFinalResize is set, it is possible that the filename
  # exists, only with a size prefixing it.  So pull out that information
  # and see if the file still exists
  if ($settings{'AllowFinalResize'}) {
    my $check_path = $path_info;
    my ($check_dir, $check_filename) = $check_path =~ m,(.*)/(.*),;
    if ($check_filename =~ s,^(\d+)x(\d+)_,,) {
      my ($max_width, $max_height) = ($1, $2);

      if (-f "$album_dir/$check_dir/$check_filename") {
	return &show_picture($r, $album_uri, "$check_dir/$check_filename",
			     \%settings, $max_width, $max_height);
      }
    }
  }
  

  # We have a directory, but does $path_info end in a
  # / like all good directories should?  If not, add
  # it and do a redirect, makes the pictures show up
  # easier later.
  unless ( $r->path_info =~ m!/$!) {
    $r->warn("Redirecting -> " . $r->uri . "/");
    $r->header_out(Location => $r->uri . "/");
    return REDIRECT;
  }

  # Try to open the directory, and read all the image file
  # that aren't thumbnails
  unless(opendir(IN,"$album_dir/$path_info")) {
    $r->log_error("Couldn't open $album_dir/$path_info: $!");
    return SERVER_ERROR;
  }
  my @files = grep { $r->lookup_uri("$album_uri/$_")->content_type =~ 
		       m!^image/! && !/^tn__/ } readdir(IN);
  closedir(IN);


  # if @files is empty, need to call show_albums
  return &show_albums($r, "$album_dir/$path_info", $path_info, \%settings)
    unless @files;

  # check to see if there is an .htaccess file there, if so
  # parse it looking for PerlSetVar's that override the defaults/
  # httpd.conf files
  if ( -f "$album_dir/$path_info/.htaccess") {
    if (open (IN,"$album_dir/$path_info/.htaccess")) {
      while (<IN>) {
	next if /^\s*$/;
	next if /^\#/;
	if (/^PerlSetVar\s+(\w+)\s+(.*)$/) {
	  my ($key,$value) = ($1,$2);
	  $settings{$key} = $value;
        }
      }
      close IN;
    }
    else {
      $r->log_error("Couldn't open $album_dir/$path_info/.htaccess: $!");
    }
  }

  @files = sort @files;
  @files = reverse @files
    if $settings{'ReversePics'};
    
  # Load up thumbnails
  # Unless the thumbnail file exists, and
  # is newer than the file it's a thumbnail for, generate the
  # thumbnail
  foreach (@files) {
    unless ( -e "$album_dir/$path_info/$settings{ThumbSubDir}/tn__$_" && 
	     (stat(_))[9] > (stat("$album_dir/$path_info/$_"))[9] ) {

      # Make sure the thumbnail directory exists
      mkdir ("$album_dir/$path_info/$settings{ThumbSubDir}", 0755) 
	unless -d "$album_dir/$path_info/$settings{ThumbSubDir}";

      # If we're allowing a final resize make sure that directory
      # exists.  By default it's the same as the ThumbSubDir

      if ($settings{'AllowFinalResize'}) {
	mkdir("$album_dir/$path_info/$settings{FinalResizeDir}", 0755)
	  unless -d "$album_dir/$path_info/$settings{FinalResizeDir}";
      }

      # Create a new thumbnail
      my $q = new Image::Magick;
      unless ($q) {
	$r->log_error("Couldn't create a new Image::Magick object");
	return SERVER_ERROR;
      }
     
      $q->Read("$album_dir/$path_info/$_");

      # Load up the current images width and height
      my ($o_width, $o_height) = $q->Get('width', 'height');
      my ($ratio, $t_width, $t_height, $t_aspect);

      # If we're using aspect, then multiply width and
      # height by the aspect ratio
      if ( $settings{'ThumbNailUse'} eq "aspect") {
	$t_aspect = $settings{'ThumbNailAspect'};
	# get the *real* aspect
	$t_aspect =~ tr[^0-9/.][];
	$t_aspect = eval($t_aspect);
	$t_width  = $o_width  * $t_aspect;
	$t_height = $o_height * $t_aspect;
      }
      else {
	# Otherwise just make the width a constant and
	# keep the same aspect ratio for the height
	$t_width =  $settings{'ThumbNailWidth'};
	$ratio = $o_width / $o_height if $o_height;
	$t_height = $t_width / $ratio if $ratio;
      }

      # Sample it down, and save the file
      $q->Sample( width => $t_width, height => $t_height );
      $q->Write("$album_dir/$path_info/$settings{ThumbSubDir}/tn__$_");

      undef $q;

      # Create smaller versions of the full size image if requested
      if ($settings{'AllowFinalResize'}) {
	my $q = new Image::Magick;
	unless ($q) {
	  $r->log_error("Couldn't create a new Image::Magick object");
	  return SERVER_ERROR;
	}

	$q->Read("$album_dir/$path_info/$_");
	$ratio = $o_width / $o_height if $o_height;

	# Large is 1024x768
	if ($o_width > 1024) {
	  my $f_height = 0;
	  $f_height = 1024 / $ratio if $ratio;

	  undef $q;
	  $q = new Image::Magick;
	  unless ($q) {
	    $r->log_error("Couldn't create a new Image::Magick object");
	    return SERVER_ERROR;
	  }

	  $q->Read("$album_dir/$path_info/$_");
	  $q->Sample( width => 1024, height => $f_height );
	  $q->Write("$album_dir/$path_info/$settings{FinalResizeDir}/1024x768_$_");
	}

	# Med is 800x600
	if ($o_width > 800) {
	  my $f_height = 0;
	  $f_height = 800 / $ratio if $ratio;

	  undef $q;
	  $q = new Image::Magick;
	  unless ($q) {
	    $r->log_error("Couldn't create a new Image::Magick object");
	    return SERVER_ERROR;
	  }

	  $q->Read("$album_dir/$path_info/$_");
	  $q->Sample( width => 800, height => $f_height );
	  $q->Write("$album_dir/$path_info/$settings{FinalResizeDir}/800x600_$_");
	}

	# Sm is 640x480
	if ($o_width > 640) {
	  my $f_height = 0;
	  $f_height = 640 / $ratio if $ratio;

	  undef $q;
	  $q = new Image::Magick;
	  unless ($q) {
	    $r->log_error("Couldn't create a new Image::Magick object");
	    return SERVER_ERROR;
	  }

	  $q->Read("$album_dir/$path_info/$_");
	  $q->Sample( width => 640, height => $f_height );
	  $q->Write("$album_dir/$path_info/$settings{FinalResizeDir}/640x480_$_");
	}
      }
  
    }
  }

  # The title will be a hacked up path_info, only the
  # last directory, transform -_ to space
  my $title = $path_info;
  $title =~ s|.*/||;
  $title =~ tr|-_|  |;

  # Send the actual web page...
  $r->content_type('text/html');
  $r->send_http_header();
  return OK if $r->header_only;

  $r->print(<<EOF);
<HTML>
<HEADER><TITLE>$title</TITLE></HEADER>
<BODY $settings{'BodyArgs'}>
EOF

  # If there is a caption.txt file, include it here
  # The caption file is copied directly to the page up
  # to the __END__ line.  At which point, the remaing
  # text in the file is considered to be captions for
  # individual files in the form:
  #
  # file.ext: Caption Here
  #
  # HTML tags are welcome in the entire file
  my $caption_file = "$album_dir/$path_info/caption.txt";
  my %picture_captions;
  my $state = "Caption";
  if ( -r $caption_file ) {
    unless (open (IN,$caption_file)) { 
      $r->log_error("Weird, $caption_file is readable, but I can't read it: $!");
      return SERVER_ERROR;
    }
    while (<IN>) {
      $state eq "Caption" && ! /^__END__$/ and $r->print($_);
      if ($state eq "Picture Captions") {
	my ($key,@rest) = split (/:/,$_);
	$picture_captions{$key} = (join(':',@rest));
      }
      /^__END__$/ and $state = "Picture Captions";
    }
    close IN;
    $r->print("<HR>\n");
  }

  # Use 'ThumbNailWidth' even though the pictures can be of a
  # different width.  Technically we could use ImageMagick to get
  # exact sizes for each row but that would slow us down, and we
  # really don't need to be all the picky, do we? :)

  # Use $settings{'DefaultBrowserWidth'} and 
  # $settings{'ThumbNailWidth'}to determine how many thumbnails per row
  $r->print(qq!<TABLE BORDER=$settings{'OutsideTableBorder'}><TR>!);
  my $pixels_so_far = $settings{'ThumbNailWidth'};
  foreach (@files) {
    my $message = $_;
    if ($picture_captions{$message}) {
      $message = $picture_captions{$message};
    }
    else {
      $message =~ tr/_-/  /;
      $message =~ s/\.[^.]*$//g;
    }

    my $resize_urls = "";

    if ($settings{'AllowFinalResize'}) {
      my $resize_strings = "";
      if (-f "$album_dir/$path_info/$settings{FinalResizeDir}/640x480_$_") {
	$resize_strings .= qq!<A HREF="640x480_$_">Sm</A>!;
      }

      if (-f "$album_dir/$path_info/$settings{FinalResizeDir}/800x600_$_") {
	$resize_strings .= qq! <A HREF="800x600_$_">Med</A>!;
      }

      if (-f "$album_dir/$path_info/$settings{FinalResizeDir}/1024x768_$_") {
	$resize_strings .= qq! <A HREF="1024x768_$_">Lg</A>!;
      }

      $resize_urls = qq!<BR>$resize_strings!
	if $resize_strings;
    }

    $r->print(qq!<TD ALIGN="center"><TABLE BORDER=$settings{'InsideTablesBorder'}><TR><TD ALIGN="center"><A HREF="$_">! .
	      qq!<IMG SRC="$album_uri/$path_info/$settings{ThumbSubDir}/tn__$_" ALT="$_"></A>$resize_urls</TD></TR>!,
	      qq!<TR><TD ALIGN="center">$message</TD></TR></TABLE></TD>\n!);
    $pixels_so_far += $settings{'ThumbNailWidth'};
    if ($pixels_so_far > $settings{'DefaultBrowserWidth'}) {
      $r->print(qq!</TR><TR>!);
      $pixels_so_far = $settings{'ThumbNailWidth'};
    }
  }

  $r->print("</TR></TABLE>\n");
  if ($settings{'EditMode'}) {
    $r->print(&file_upload());
  }
  $r->print("<hr>\n$settings{'Footer'}\n<hr>") if $settings{'Footer'};
  $r->print(<<EOF);
<HR>
<address>Generated by Apache::Album</address>
</BODY>
</HTML>
EOF

    return OK;
}

# show_albums simply shows the albums under the directory
# it should probably not be called, a "real" web page with
# links to the albums would probably be better, but this
# helps when debugging, or if someone decides to go to this
# directory directly
sub show_albums {
  my ($r, $album_dir, $path_info, $settings) = @_;

  unless ($r->uri =~ m|/$|) {
    $r->log_error("Redirecting -> " . $r->uri . "/");
    $r->header_out(Location => $r->uri . "/");
    return REDIRECT;
  }

  unless (opendir(IN,$album_dir)) {
    $r->log_error("Could not open $album_dir: $!");
    return SERVER_ERROR;
  }
  
  my @dirs = grep { -d "$album_dir/$_" && ! /^\./ } readdir(IN);
  closedir(IN);

  $r->content_type('text/html');
  $r->send_http_header();
  return OK if $r->header_only;

  $r->print(<<EOF);
<HTML><HEADER><TITLE>Available Albums</TITLE></HEADER>
<BODY $$settings{'BodyArgs'}>
<H3>Available Albums</H3>
EOF

  $r->print($path_info)
    if $path_info;

  @dirs = sort @dirs;
  @dirs = reverse @dirs
    if $settings->{'ReverseDirs'};
  
  foreach (@dirs) {
    &list_dirs($r, $album_dir, $_, "", $settings );
  }

  if ($settings->{'EditMode'}) {
    $r->print(qq!<FORM METHOD="POST">New Album:<INPUT TYPE="text" NAME="AlbumName"><INPUT TYPE="submit" NAME="New Album" VALUE="New Album"></FORM>!);

    unless (@dirs) {
      $r->print(&file_upload());
    }
  }


  $r->print(<<EOF);
<HR>
<address>Apache::Album</address>
</BODY>
</HTML>
EOF

  return OK;  
}

# Show picture shows the actual full sized picture,
# I might add some cool things like filters and 
# such since we use ImageMagick for the thumbnails
# For now, just show the picture and a caption
sub show_picture {
  my ($r, $album_uri, $path_info, $settings) = @_[0..3];
  my $album_dir = $r->lookup_uri($album_uri)->filename;

  my $caption = $path_info;

  my $modified_path_info = "$album_uri/$path_info";
  my $start_link = "";
  my $end_link = "";

  $caption =~ s!.*/!!;
  $caption =~ s!\.[^.]*$!!;
  $caption =~ tr[-_][  ];
  $caption = qq!<H3>$caption</H3>!;

  my ($path_dir,$path_file) = $path_info =~ m!(.*)/(.*)!;

  if ($settings->{'AllowFinalResize'}) {
    my ($max_width, $max_height) = @_[4,5];

    if ($max_width > 0) {
      $modified_path_info = "$album_uri/$path_dir/"
	. $settings->{FinalResizeDir}
      . "/${max_width}x${max_height}_$path_file";

      $start_link = qq!<A HREF="$path_file" BORDER="0">!;
      $end_link = qq!</A>!;
    }
  }

  # check for a content.txt file, if I find one
  # parse it in case there is a caption for this
  # picture.
  if ( -f "$album_dir/$path_dir/caption.txt" ) {
    unless (open (IN,"$album_dir/$path_dir/caption.txt")) {
      $r->log_error("Could not open $album_dir/$path_dir/caption.txt: $!");
      return SERVER_ERROR;
    }
    
    my $found_end = 0;
    while (<IN>) {
      if (/^__END__/) {
	$found_end = 1;
	last;
      }
    }
    
    if ($found_end) { # Finish parsing file
      while (<IN>) {
	my ($key,@rest) = split(/:/, $_);
	next if $key ne $path_file;
	$caption = join(':',@rest);
      }
    }
	
    close (IN);
  }

  $r->content_type('text/html');
  $r->send_http_header();
  $r->print(<<EOF);
<HTML><HEADER><TITLE>$caption</TITLE></HEADER>
<BODY $$settings{'BodyArgs'}>
<CENTER>$start_link<IMG SRC="$modified_path_info" ALT="$path_info">$end_link
<HR>
$caption</CENTER>
<HR>
  <address>Brought to you by Apache::Album</address>
</BODY>
</HTML>
EOF
  ;
  return OK;
}

# list_dirs takes the passed directory list
# and recursively prints out lists of directories
# below the passed directory
sub list_dirs {
  my ($r, $album_dir, $directory, $old_directory, $settings) = @_;

  my $text = $directory;
  $text =~ tr[-_][  ];
  $text =~ s,\d+\((.*)\),\1,;
  $r->print(qq!<dl><dt><A HREF="$old_directory$directory/">$text</A></dt>\n!);

  my @dirs = ();

  my $thumb_dir = $settings->{'ThumbSubDir'};

  if ($settings->{'AllowFinalResize'}
      && ($settings->{'ThumbSubDir'} ne $settings->{'FinalResizeDir'})) {
    $thumb_dir = "($thumb_dir|"
      . $settings->{'FinalResizeDir'}
      . ")";
  }

  if (opendir(IN, "$album_dir/$directory")) {
    @dirs = grep { -d "$album_dir/$directory/$_" 
		     && ! /^\./
		       && ! m,$thumb_dir$,
		   } readdir(IN);
    closedir(IN);
  }
  else {
    $r->log_error("Could not open $album_dir/$directory: $!");
  }

  @dirs = sort @dirs;

  @dirs = reverse @dirs
    if $settings->{'ReverseDirs'};

  foreach (@dirs) {
    &list_dirs($r, "$album_dir/$directory", $_, "$old_directory$directory/", $settings);
  }

  $r->print(qq!</dl>!);
}

# file_upload is just the html for the file upload
# it's in a sub since it will be called from multiple 
# places
sub file_upload {

  my $ret = <<EOF
<FORM METHOD="POST" ENCTYPE="multipart/form-data">
  <INPUT TYPE="submit" NAME="Upload" VALUE="Upload">
  <INPUT TYPE="file" NAME="filename" SIZE=50 MAXLENGTH=200>
</FORM>
EOF
  ;

  return $ret;

}

1;
__END__

=head1 NAME

Apache::Album - Simple mod_perl Photo Album

=head1 SYNOPSIS

Add to httpd.conf

 <Location /albums>
   SetHandler perl-script
   PerlHandler Apache::Album
#   PerlSetVar  AlbumDir            /albums_loc
#   PerlSetVar  ThumbNailUse        Width  
#   PerlSetVar  ThumbNailWidth      100
#   PerlSetVar  ThumbNailAspect     2/11
#   PerlSetVar  ThumbSubDir         thumbs
#   PerlSetVar  DefaultBrowserWidth 640
#   PerlSetVar  OutsideTableBorder  0
#   PerlSetVar  InsideTablesBorder  0
#   PerlSetVar  BodyArgs            BGCOLOR=white
#   PerlSetVar  Footer              "<EM>Optional Footer Here</EM>"
#   PerlSetVar  EditMode            0
#   PerlSetVar  AllowFinalResize    0
#   PerlSetVar  FinalResizeDir      thumbs
#   PerlSetVar  ReverseDirs         0
#   PerlSetVar  ReversePics         0
 </Location>

=head1 ABSTRACT

This is a simple photo album.  You simply copy some gif's/jpeg's to a
directory, create an optional text block (in a file called
caption.txt) to go at the top, and the module does the rest.  It does
however require that PerlMagick be installed.

Default settings in the httpd.conf file may be overriden by creating a
.htaccess file in the same directory as the image files and the
caption.txt file.

=head1 INSTALLATION

  perl Makefile.PL
  make
  make install

(no test necessary)

=head1 CONFIGURATION

The configuration can be a little tricky, so here is a little more
information.  It's important to realize that there are two separate,
but related directories.  One is where the physical pictures reside,
the other is where the "virtual" albums reside.

Consider a filesystem called /albums exists and it is this filesystem
that will house the images.  Also consider that multiple people will
have albums there, so you would create a directory for each user:

  /albums/jdw/albums_loc
  /albums/travis/albums_loc

Then in your httpd.conf file you would have the following entry to
allow pictures in those directories to be viewed:

  Alias /jdw /albums/jdw/

At this point you could view a full sized picture under the directory
/albums/jdw/albums_loc as the url /jdw/albums_loc.

To have an album that creates thumbnails/captions of those pictures
you would need an entry like:

 <Location /jdw/albums>
  SetHandler perl-script
  AllowOverride None
  Options None
  PerlHandler Apache::Album
  PerlSetVar  AlbumDir /jdw/albums_loc
  PerlSetVar  Footer   "<a href=\"mailto:woody@bga.com\">Jim Woodgate</a>"
 </Location>

Note how AlbumDir points to the url where the files exist, and the url
you use to access the album will be just like that url, only
substituting albums for albums_loc.

If anyone knows of a way to accomplish this same thing, but using a
DirectoryIndex instead, please let me know.  I tried and could not get
it to work!

=head1 DESCRIPTION

This module sets up a virtual set of photo albums starting at the
C<Location> definition.  This virtual directory is mapped to a
physical directory under C<AlbumDir>.  Under C<AlbumDir> create a
sub-directory for each photo album, and copy image files into each
subdirectory.  You must also make the permissions for each
subdirectory so that the id which runs Apache can write to the
directory.

At this point, if you have PerlMagick installed, you can go to
I<http://your.site/albums/album_name> Apache::Album will create
thumbnails for each of the images, and send the caption.txt file along
with the thumbnails to the client's browser.  The thumbnails are links
to the full sized images.

=over 2

=item The caption.txt file

The caption.txt file consists of two parts.  The first part is
text/html, that will be placed at the top of the html document.  The
second part is a mapping of filenames to captions.  The module will do
some simple mangling of the image file names to create the caption.
But if it finds a mapping in the caption.txt file, that value is used
instead.  The value __END__ signifies the end of the first section and
the beginning of the second.

  For example:

  Image   -> Bob_and_Jenny.jpg
  Caption -> Bob and Jenny       (the auto-generated caption)

  override in caption.txt
  Bob_and_Jenny.jpg: This is me with my sister <EM>Jenny</EM>.

Here is a sample caption.txt file:

  <H1>My Birthday Party</H1>

  <center>This is me at my Birthday Party!.</center>

  __END__
  pieinface.gif: Here's me getting hit the face with a pie.
  john5.jpg: This is <A HREF="mailto:johndoe@nowhere.com">John</A>

=item ThumbNail Types

C<ThumbNailUse> can either be set to "width" or "aspect".  If
C<ThumbNailUse> is set to "width", thumbnails that need to be created
will be C<ThumbNailWidth> wide, and the height will be modified to
keep the same aspect as the original image.

If C<ThumbNailUse> is set to "aspect", thumbnails that need to be
created will be transformed by the value of C<ThumbNailAspect>.
C<ThumbNailAspect> can be either a floating point number like 0.25 or
it can be a ratio like 2 / 11.

If an image file is updated, the corresponding thumbnail file will be
updated the next time the page is accessed.  In practice I have found
that Netscape will used the cached images even if they are updated.  I
normally have to flush the cache and reload to see the new images.

At any time you can C<rm -f tn__*> in the C<AlbumDir>/album_name/
directory, the next time the page is loaded all the thumbnails will be
regenerated.  (Naturally image names that start with tn__ should be
renamed before placing them in the album directory.)

=item ThumbSubDir

If you want your thumbnails to be in a different directory than the
original pictures, set C<ThumbSubDir> which is the subdirectory the
thumbnails will be created in and viewed from.  (This could also be
used to allow multiple sets of thumbnails).

=item DefaultBrowserWidth

A general number of how wide you want the final table to be, not an
absolute number.  If the next image would take it past this "invisible
line", a new row is started.

=item BodyArgs

This entire string is passed in the <BODY> tag.  Useful for setting
background images, background color, link colors, etc.  If set in the
httpd.conf file, you must put quotes around the value, and escape any
quotes in the value.  If this value is set in the .htaccess file, this
is not necessary:

  In httpd.conf: PerlSetVar BodyArgs "BACKGROUND=gray.gif text=\"#FFFFFF\""
  In .htaccess : PerlSetVar BodyArgs BACKGROUND=gray.gif text="#FFFFFF"

=item OutsideTableBorder

This variable's value is passed to the outer table's BORDER attribute.

=item InsideTablesBorder

This variables's value is passed to all the inner table's BORDER
attributes.  Note that the name of the C<InnerTablesBorder> has an 's'
in it, as it modifes all the inner tables.

=item Footer

This text/html will placed at the bottom of the page after all the
thumbnails, but before the end of the page.  Useful for links back to
a home page, mailto: tag, etc.

=item EditMode

Allows the user to create new albums and upload pictures.  Obviously
there are security implications here, so if EditMode is turned on that
location should probably have some kind of security.  Albums can share
the same AlbumDir, so you can have something like:

/albums      - ReadOnly version, no security
/albums_edit - Allow new album creation and picture uploads, 
               require authentication

both using the same AlbumDir.

=item AllowFinalResize

If this is set to true, the user will have 3 additional options when
viewing the full sized picture.  The thumbnail can still be selected
to view the full picture, or Sm (Small), Med (Medium), or Lg(Large)
can be selected to bring the picture down to fit better in a 640x480,
800x600, or 1024x758 screen.

=item ReverseDirs

When viewing albums, they will be sorted by name.  If this is set to
true the order will be reversed.  (Useful if you want to use things
like dates/months as the directory names, this will put the most
recent albums first.

=item ReversePics

When viewing pictures, they will be sorted by name.  If this is set to
true, the order of the pictures will be reversed.

=back

=head1 LIMITATIONS 

PerlMagick is a limiting factor.  If PerlMagick can't load the image,
no thumbnail will be created.

=head1 COPYRIGHT

Copyright (c) 1998-1999 Jim Woodgate. All rights reserved. This
program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=head1 AUTHOR

Jim Woodgate woody@bga.com

=head1 SEE ALSO

perl(1), L<Image::Magick>(3).

=cut
