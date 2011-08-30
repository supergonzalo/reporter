#INFO: write convenient expressions (like a WHERE clause), generate SQL commands from them

sub exprToTables {
	#D: extract table aliases from expr
	my ($e)= @_;
	my %tableAlias= ();
	while ($e =~ /(\w*)\.?t\s*=\s*[\"\']?(\w+)[\"\']?/gi) { $tableAlias{lc($1 || $2)}= uc($2); }
	#A: got tables declared with "AnALIAS.t = Atable"
	while ($e =~ /(\w+)\.(\w+)/gi) { $tableAlias{lc($1)} ||= uc($1); }
	#A: got tables used explicitly
	logm("DBG",9,"DB TABLES #1 FROM EXPR #2",\%tableAlias,$e);
	return %tableAlias;
}

sub exprToSelect {
	my ($e,$multi)= @_;
	my %tableAlias= exprToTables($e);
	my $fields= $multi ? join(", ",map("1 as TaBlE_$tableAlias{$_}, $tableAlias{$_}.*",keys(%tableAlias))) : "*";
	my $r= "SELECT $fields from " . join(", ",map("$_ as $tableAlias{$_}",keys(%tableAlias))) . " WHERE " . $e;
	return $r;
}

sub exprToAssignments {
	my ($e)= @_;
	my %tableAlias= exprToTables($e);
	my $aliasDflt= (keys(%tableAlias))[0];
	my %assignments= (); #one by table alias
	$e .= " AND"; 
	while ($e =~ /(?:(\w+)\.)?(\w+)\s*=\s*(.+?)\s+AND/gi) { 
		my $a= lc($1) || $aliasDflt;
		my $c= uc($2); 
		my $v= $3;
		logm("DBG",9,"ASS: a='$a' c='$c' v='$v' FROM '$&'");
		$assignments{$a}||= { TABLE => $tableAlias{$a}, KV => [] };
		push @{$assignments{$a}{KV}}, [ $c, $3 ];
	}
	return %assignments;
}

sub exprToDML {
	my ($eNew,$eOld)= @_;
	my %assignments= exprToAssignments($eNew);
	my %assignments2= exprToAssignments($eOld . " AND " . $eNew);
	my %r= ();
	my ($alias, $a);
	while(($alias,$a) = each(%assignments)) {
			$r{$alias}= {
				UPDATE => "UPDATE $$a{TABLE} SET " . join(", ",map({$$_[0] . "= " . $$_[1]} @{$$a{KV}})) . " WHERE " . $eOld 
			};
			#XXX: eOld must refer ONLY to cols in this table
	}	
	while(($alias,$a) = each(%assignments2)) {
			$r{$alias}{INSERT} = "INSERT INTO $$a{TABLE} (" . join(", ",map({$$_[0]} @{$$a{KV}})) . ") VALUES (" . join(", ",map({$$_[1]} @{$$a{KV}})) . ")";
			$r{$alias}{CREATE} = "CREATE TABLE $$a{TABLE} (AID INTEGER PRIMARY KEY AUTOINCREMENT, " . join(", ",map({$$_[0] . " text"} @{$$a{KV}})) . ", DATAVER INTEGER DEFAULT 0, UNIQUE ( " . join(", ",map({$$_[0]} @{$$a{KV}})) . "))";
	}
	logm("DBG",9,"EXPR TO DML OLD=#1 NEW=#2 R=#3",$eNew, $eOld, \%r);
	return %r;
}

sub exprFromData {
	my ($d)= @_;
	if (ref($d) =~ /HASH/) {
		$d= [$$d{'T'}, grep({uc($_) ne 'T'} keys(%$d))];		
	}

	if (ref($d) =~ /ARRAY/) {
		my $t= shift(@$d);
		$d= "T=\"$t\" AND " . join(" AND ", map("$_ = ?$_", @$d));		
	}

	return $d;
}

sub sqlAndParams {
	#D: extract NAMED parameters from SQL, result can be used giving a DICT with values for the parameter names and evaluating prepare($sql), exec(@values{@p});
	my ($e)= @_;
	my @p= ();
	$e =~ s/\?(\w*)/push @p, ($1 || ("param" . scalar(@p))); "?"/gse;
	return ($e, \@p);
}

1;

