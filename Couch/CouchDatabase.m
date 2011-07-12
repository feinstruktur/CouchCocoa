//
//  CouchDatabase.m
//  CouchCocoa
//
//  Created by Jens Alfke on 5/26/11.
//  Copyright 2011 Couchbase, Inc. All rights reserved.
//

#import "CouchDatabase.h"
#import "RESTCache.h"
#import "CouchChangeTracker.h"
#import "CouchDesignDocument.h"
#import "CouchInternal.h"

#import "JSONKit.h"


NSString* const kCouchDocumentChangeNotification = @"CouchDocumentChange";

/** Number of CouchDocument objects to cache in memory */
static const NSUInteger kDocRetainLimit = 50;


@implementation CouchDatabase


- (void)dealloc {
    self.tracksChanges = NO;
    [super dealloc];
}


- (CouchServer*) server {
    return (CouchServer*)[self parent];
}


- (CouchDatabase*) database {
    return self;
}


- (RESTOperation*) create {
    return [self PUT: nil parameters: nil];
}


- (NSInteger) getDocumentCount {
    id count = [[self GET].responseBody.fromJSON objectForKey: @"doc_count"];  // synchronous
    return [count isKindOfClass: [NSNumber class]] ? [count intValue] : -1;
}


- (CouchDocument*) documentWithID: (NSString*)docID {
    CouchDocument* doc = (CouchDocument*) [_docCache resourceWithRelativePath: docID];
    if (!doc) {
        if ([docID hasPrefix: @"_design/"])     // Create a design doc when appropriate
            doc = [[CouchDesignDocument alloc] initWithParent: self relativePath: docID];
        else
            doc = [[CouchDocument alloc] initWithParent: self relativePath: docID];
        if (!doc)
            return nil;
        if (!_docCache)
            _docCache = [[RESTCache alloc] initWithRetainLimit: kDocRetainLimit];
        [_docCache addResource: doc];
        [doc release];
    }
    return doc;
}


- (CouchDesignDocument*) designDocumentWithName: (NSString*)name {
    return (CouchDesignDocument*)[self documentWithID: [@"_design/" stringByAppendingString: name]];
}
            
            
- (CouchDocument*) untitledDocument {
    return [[[CouchDocument alloc] initUntitledWithParent: self] autorelease];
}


- (void) documentAssignedID: (CouchDocument*)document {
    if (!_docCache)
        _docCache = [[RESTCache alloc] init];
    [_docCache addResource: document];
}


- (void) clearDocumentCache {
    [_docCache forgetAllResources];
}


- (RESTOperation*) putChanges: (NSArray*)properties toRevisions: (NSArray*)revisions {
    // http://wiki.apache.org/couchdb/HTTP_Bulk_Document_API
    NSUInteger nRevisions = revisions.count;
    NSAssert(properties.count == nRevisions, @"Mismatched array counts");
    NSMutableArray* entries = [NSMutableArray arrayWithCapacity: nRevisions];
    for (NSUInteger i=0; i<nRevisions; i++) {
        CouchRevision* revision = [revisions objectAtIndex: i];
        NSMutableDictionary* props = [[properties objectAtIndex: i] mutableCopy];
        [props setObject: revision.documentID forKey: @"_id"];
        [props setObject: revision.revisionID forKey: @"_rev"];
        [entries addObject: props];
        [props release];
    }
    NSDictionary* body = [NSDictionary dictionaryWithObject: entries forKey: @"docs"];
    
    RESTResource* bulkDocs = [[[RESTResource alloc] initWithParent: self 
                                                      relativePath: @"_bulk_docs"] autorelease];
    RESTOperation* op = [bulkDocs POSTJSON: body parameters: nil];
    [op onCompletion: ^{
        if (op.isSuccessful) {
            NSArray* responses = $castIf(NSArray, op.responseBody.fromJSON);
            //op.representedObject = responses;
            int i = 0;
            for (id response in responses) {
                CouchRevision* revision = [revisions objectAtIndex: i++];
                [revision.document bulkSaveCompleted: $castIf(NSDictionary, response)];
            }
        }
    }];
    return op;
}


#pragma mark -
#pragma mark QUERIES


- (CouchQuery*) getAllDocuments {
    CouchQuery *query = [[[CouchQuery alloc] initWithParent: self relativePath: @"_all_docs"] autorelease];
    query.prefetch = YES;
    return query;
}


- (CouchQuery*) getDocumentsWithIDs: (NSArray*)docIDs {
    CouchQuery *query = [self getAllDocuments];
    query.keys = docIDs;
    query.prefetch = YES;
    return query;
}


- (CouchQuery*) slowQueryWithViewDefinition:(struct CouchViewDefinition)definition
{
    return [[[CouchFunctionQuery alloc] initWithDatabase: self
                                          viewDefinition: definition] autorelease];
}

- (CouchQuery*) slowQueryWithMapFunction: (NSString*)mapFunctionSource {
    CouchViewDefinition defn = {mapFunctionSource, nil, kCouchLanguageJavaScript};
    return [self slowQueryWithViewDefinition: defn];
}



#pragma mark -
#pragma mark TRACKING CHANGES:


- (NSUInteger) lastSequenceNumber {
    if (_lastSequenceNumber == 0) {
        // Don't know the current sequence number, so ask for it:
        id seqObj = [[self GET].responseBody.fromJSON objectForKey: @"update_seq"];  // synchronous
        if ([seqObj isKindOfClass: [NSNumber class]])
            _lastSequenceNumber = [seqObj intValue];
    }
    return _lastSequenceNumber;
}


- (void) setLastSequenceNumber:(NSUInteger)lastSequenceNumber {
    _lastSequenceNumber = lastSequenceNumber;
}


// <http://wiki.apache.org/couchdb/HTTP_database_API#Changes>


static NSString* const kTrackingPath = @"_changes?feed=continuous";


- (void) onChange: (OnDatabaseChangeBlock)block {
    NSAssert(!_onChange, @"Sorry, only one onChange handler at a time"); // TODO: Allow multiple onChange blocks!
    _onChange = [block copy];
}


- (void) receivedChange: (NSDictionary*)change
{
    // Get & check sequence number:
    NSNumber* sequenceObj = $castIf(NSNumber, [change objectForKey: @"seq"]);
    if (!sequenceObj)
        return;
    NSUInteger sequence = [sequenceObj intValue];
    if (sequence <= _lastSequenceNumber)
        return;
    
    // Get document:
    NSString* docID = [change objectForKey: @"id"];
    CouchDocument* document = [self documentWithID: docID];
    
    // Notify!
    if ([document notifyChanged: change]) {
        if (_onChange)
            _onChange(document);
        NSNotification* n = [NSNotification notificationWithName: kCouchDocumentChangeNotification
                                                          object: self
                                                        userInfo: change];
        [[NSNotificationCenter defaultCenter] postNotification: n];
    } else {
        NSLog(@"    CouchDatabase change with seq=%lu already known", (unsigned long)sequence);
    }
    
    _lastSequenceNumber = sequence;
}


- (void) receivedChangeLine: (NSData*)chunk {
    NSString* line = [[[NSString alloc] initWithData: chunk encoding:NSUTF8StringEncoding] autorelease];
    if (!line) {
        Warn(@"Couldn't parse UTF-8 from _changes");
        return;
    }
    if (line.length == 0 || [line isEqualToString: @"\n"])
        return;
    NSDictionary* change = $castIf(NSDictionary, [line objectFromJSONString]);
    if (change) {
        NSLog(@"**** CHANGED: %@", line);
        [self receivedChange: change];
    } else {
        Warn(@"Received unparseable change line from server: %@", line);
    }
}


- (BOOL) tracksChanges {
    return _tracker != nil;
}


- (void) setTracksChanges: (BOOL)track {
    if (track && !_tracker) {
        _tracker = [[CouchChangeTracker alloc] initWithDatabase: self
                                                 sequenceNumber: _lastSequenceNumber];
        [_tracker start];
    } else if (!track && _tracker) {
        [_tracker stop];
        [_tracker release];
        _tracker = nil;
    }
}


@end