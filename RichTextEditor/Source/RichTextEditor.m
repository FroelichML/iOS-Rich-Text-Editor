//
//  RichTextEditor.m
//  RichTextEdtor
//
//  Created by Aryan Gh on 7/21/13.
//  Copyright (c) 2013 Aryan Ghassemi. All rights reserved.
//
// https://github.com/aryaxt/iOS-Rich-Text-Editor
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

// stackoverflow.com/questions/26454037/uitextview-text-selection-and-highlight-jumping-in-ios-8

#import "RichTextEditor.h"
#import <QuartzCore/QuartzCore.h>
#import "UIFont+RichTextEditor.h"
#import "NSAttributedString+RichTextEditor.h"
#import "UIView+RichTextEditor.h"

#define RICHTEXTEDITOR_TOOLBAR_HEIGHT 40
// removed first tab in lieu of using indents for bulleted lists
#define BULLET_STRING @"•\t"
#define LEVELS_OF_UNDO 10

@interface RichTextEditor() <RichTextEditorToolbarDelegate, RichTextEditorToolbarDataSource>
@property (nonatomic, strong) RichTextEditorToolbar *toolBar;

// Gets set to YES when the user starts changing attributes when there is no text selection (selecting bold, italic, etc)
// Gets set to NO  when the user changes selection or starts typing
@property (nonatomic, assign) BOOL typingAttributesInProgress;

// The RTE will not be deallocated while the text observer is active. It is the RTE owner's
// responsibility to call the removeTextObserverForDealloc function.
@property id textObserver;

@property float currSysVersion;

@end

@implementation RichTextEditor

#pragma mark - Initialization -

- (id)init
{
    if (self = [super init])
	{
        [self commonInitialization];
    }
	
    return self;
}

- (id)initWithFrame:(CGRect)frame
{
    if (self = [super initWithFrame:frame])
	{
        [self commonInitialization];
    }
	
    return self;
}

- (id)initWithCoder:(NSCoder *)aDecoder
{
	if (self = [super initWithCoder:aDecoder])
	{
		[self commonInitialization];
	}
	
	return self;
}

- (void)commonInitialization
{
    self.borderColor = [UIColor lightGrayColor];
    self.borderWidth = 1.0;
    
	self.toolBar = [[RichTextEditorToolbar alloc] initWithFrame:CGRectMake(0, 0, [self currentScreenBoundsDependOnOrientation].size.width, RICHTEXTEDITOR_TOOLBAR_HEIGHT)
													   delegate:self
													 dataSource:self];
	
	self.typingAttributesInProgress = NO;
    self.userInBulletList = NO;
    
    // Instead of hard-coding the default indentation size, which can make bulleted lists look a little
    // odd when increasing/decreasing their indent, use a \t character width instead
    // The old defaultIndentationSize was 15
    // TODO: readjust this defaultIndentationSize when font size changes? Might make things weird.
	NSDictionary *dictionary = [self dictionaryAtIndex:self.selectedRange.location];
    CGSize expectedStringSize = [@"\t" sizeWithAttributes:dictionary];
	self.defaultIndentationSize = expectedStringSize.width;
    
	[self setupMenuItems];
	[self updateToolbarState];
    if (self.dataSource && [self.dataSource respondsToSelector:@selector(levelsOfUndo)])
        [[self undoManager] setLevelsOfUndo:[self.dataSource levelsOfUndo]];
    else [[self undoManager] setLevelsOfUndo:LEVELS_OF_UNDO];
	
	// When text changes check to see if we need to add bullet, or delete bullet on backspace/enter
	_textObserver = [[NSNotificationCenter defaultCenter] addObserverForName:UITextViewTextDidChangeNotification
													  object:self
													   queue:nil
												  usingBlock:^(NSNotification *n){
													  [self applyBulletListIfApplicable];
													  [self deleteBulletListWhenApplicable];
												  }];
    [self setDelegate:self];
    
    // http://stackoverflow.com/questions/26454037/uitextview-text-selection-and-highlight-jumping-in-ios-8
    self.currSysVersion = [[[UIDevice currentDevice] systemVersion] floatValue];
    if (self.currSysVersion >= 8.0)
        self.layoutManager.allowsNonContiguousLayout = NO;
}

-(void)dealloc {
    self.toolBar = nil;
}

-(void)removeTextObserverForDealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:_textObserver];
    _textObserver = nil;
}

- (void)textViewDidChangeSelection:(UITextView *)textView
{
    //NSLog(@"[RTE] Changed selection to location: %lu, length: %lu", (unsigned long)textView.selectedRange.location, (unsigned long)textView.selectedRange.length);
    [self updateToolbarState];
    [self setNeedsLayout];
    [self scrollRangeToVisible:self.selectedRange]; // fixes issue with cursor moving to top via keyboard and RTE not scrolling
    
	NSRange rangeOfCurrentParagraph = [self.attributedText firstParagraphRangeFromTextRange:self.selectedRange];
	BOOL currentParagraphHasBullet = ([[[self.attributedText string] substringFromIndex:rangeOfCurrentParagraph.location] hasPrefix:BULLET_STRING]) ? YES: NO;
    if (currentParagraphHasBullet)
        self.userInBulletList = YES;
}

#pragma mark - Override Methods -

- (void)setSelectedTextRange:(UITextRange *)selectedTextRange
{
	[super setSelectedTextRange:selectedTextRange];
	
	[self updateToolbarState];
	self.typingAttributesInProgress = NO;
}

- (BOOL)canBecomeFirstResponder
{
	if (![self.dataSource respondsToSelector:@selector(shouldDisplayToolbarForRichTextEditor:)] ||
		[self.dataSource shouldDisplayToolbarForRichTextEditor:self])
	{
		self.inputAccessoryView = self.toolBar;
		
		// Redraw in case enabled features have changes
		[self.toolBar redraw];
	}
	else
	{
		self.inputAccessoryView = nil;
	}
	// changed to YES so that we can use keyboard shortcuts
	return YES /*[super canBecomeFirstResponder]*/;
}

- (BOOL)canPerformAction:(SEL)action withSender:(id)sender
{
	RichTextEditorFeature features = [self featuresEnabledForRichTextEditorToolbar];
	
	if ([self.dataSource respondsToSelector:@selector(shouldDisplayRichTextOptionsInMenuControllerForRichTextEditor:)] &&
		[self.dataSource shouldDisplayRichTextOptionsInMenuControllerForRichTextEditor:self])
	{
		if (action == @selector(richTextEditorToolbarDidSelectBold) && (features & RichTextEditorFeatureBold  || features & RichTextEditorFeatureAll))
			return YES;
		
		if (action == @selector(richTextEditorToolbarDidSelectItalic) && (features & RichTextEditorFeatureItalic  || features & RichTextEditorFeatureAll))
			return YES;
		
		if (action == @selector(richTextEditorToolbarDidSelectUnderline) && (features & RichTextEditorFeatureUnderline  || features & RichTextEditorFeatureAll))
			return YES;
		
		if (action == @selector(richTextEditorToolbarDidSelectStrikeThrough) && (features & RichTextEditorFeatureStrikeThrough  || features & RichTextEditorFeatureAll))
			return YES;
	}
	
	if (action == @selector(selectParagraph:) && self.selectedRange.length > 0)
		return YES;
	
	return [super canPerformAction:action withSender:sender];
}

- (void)setAttributedText:(NSAttributedString *)attributedText
{
	[super setAttributedText:attributedText];
	[self updateToolbarState];
}

- (void)setText:(NSString *)text
{
	[super setText:text];
	[self updateToolbarState];
}

- (void)setFont:(UIFont *)font
{
	[super setFont:font];
	[self updateToolbarState];
}

#pragma mark - MenuController Methods -

- (void)setupMenuItems
{
	UIMenuItem *selectParagraph = [[UIMenuItem alloc] initWithTitle:@"Select Paragraph" action:@selector(selectParagraph:)];
	UIMenuItem *boldItem = [[UIMenuItem alloc] initWithTitle:@"Bold" action:@selector(richTextEditorToolbarDidSelectBold)];
	UIMenuItem *italicItem = [[UIMenuItem alloc] initWithTitle:@"Italic" action:@selector(richTextEditorToolbarDidSelectItalic)];
	UIMenuItem *underlineItem = [[UIMenuItem alloc] initWithTitle:@"Underline" action:@selector(richTextEditorToolbarDidSelectUnderline)];
	//UIMenuItem *strikeThroughItem = [[UIMenuItem alloc] initWithTitle:@"Strike" action:@selector(richTextEditorToolbarDidSelectStrikeThrough)]; // buggy on ios 8, scrolls the text for some reason; not sure why
	
	[[UIMenuController sharedMenuController] setMenuItems:@[selectParagraph, boldItem, italicItem, underlineItem]];
}

- (void)selectParagraph:(id)sender
{
	NSRange range = [self.attributedText firstParagraphRangeFromTextRange:self.selectedRange];
	[self setSelectedRange:range];
    
	[[UIMenuController sharedMenuController] setTargetRect:[self frameOfTextAtRange:self.selectedRange] inView:self];
	[[UIMenuController sharedMenuController] setMenuVisible:YES animated:YES];
}

#pragma mark - Public Methods -

- (void)setHtmlString:(NSString *)htmlString
{
    NSAttributedString *attr = [RichTextEditor attributedStringFromHTMLString:htmlString];
    if (attr)
        self.attributedText = attr;
}

- (NSString *)htmlString
{
    return [RichTextEditor htmlStringFromAttributedText:self.attributedText];
}

+(NSString *)htmlStringFromAttributedText:(NSAttributedString*)text
{
	if (!SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(@"7.0"))
	{
		NSLog(@"Method setHtmlString is only supported on iOS 7 and above");
		return nil;
	}
	
	NSData *data = [text dataFromRange:NSMakeRange(0, text.length)
                    documentAttributes:
                        @{NSDocumentTypeDocumentAttribute: NSHTMLTextDocumentType,
                        NSCharacterEncodingDocumentAttribute: [NSNumber numberWithInt:NSUTF8StringEncoding]}
                    error:nil];
	
	return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

+(NSAttributedString*)attributedStringFromHTMLString:(NSString *)htmlString
{
	if (!SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(@"7.0"))
	{
		NSLog(@"Method setHtmlString is only supported on iOS 7 and above");
		return nil;
	}
    
	NSError *error ;
	NSData *data = [htmlString dataUsingEncoding:NSUTF8StringEncoding];
	NSAttributedString *str =
    [[NSAttributedString alloc] initWithData:data
                                     options:@{NSDocumentTypeDocumentAttribute: NSHTMLTextDocumentType,
                                               NSCharacterEncodingDocumentAttribute: [NSNumber numberWithInt:NSUTF8StringEncoding]}
                          documentAttributes:nil error:&error];
	if (error)
		NSLog(@"[RTE] Attributed string from HTML string %@", error);
	else {
		return str;
    }
    return nil;
}

- (void)setBorderColor:(UIColor *)borderColor
{
    self.layer.borderColor = borderColor.CGColor;
}

- (void)setBorderWidth:(CGFloat)borderWidth
{
    self.layer.borderWidth = borderWidth;
}

#pragma mark - RichTextEditorToolbarDelegate Methods -

- (void)richTextEditorToolbarDidDismissViewController
{
	if (![self isFirstResponder])
		[self becomeFirstResponder];
}

// To fix the toolbar issues, may just want to set self.typingAttributesInProgress to YES instead
- (void)richTextEditorToolbarDidSelectBold
{
    UIFont *font = [[self typingAttributes] objectForKey:NSFontAttributeName];
	[self applyFontAttributesToSelectedRangeWithBoldTrait:[NSNumber numberWithBool:![font isBold]] italicTrait:nil fontName:nil fontSize:nil];
}

- (void)richTextEditorToolbarDidSelectItalic
{
    UIFont *font = [[self typingAttributes] objectForKey:NSFontAttributeName];
	[self applyFontAttributesToSelectedRangeWithBoldTrait:nil italicTrait:[NSNumber numberWithBool:![font isItalic]] fontName:nil fontSize:nil];
}

- (void)richTextEditorToolbarDidSelectFontSize:(NSNumber *)fontSize
{
	[self applyFontAttributesToSelectedRangeWithBoldTrait:nil italicTrait:nil fontName:nil fontSize:fontSize];
}

- (void)richTextEditorToolbarDidSelectFontWithName:(NSString *)fontName
{
	[self applyFontAttributesToSelectedRangeWithBoldTrait:nil italicTrait:nil fontName:fontName fontSize:nil];
}

- (void)richTextEditorToolbarDidSelectTextBackgroundColor:(UIColor *)color
{
	if (color)
		[self applyAttributesToSelectedRange:color forKey:NSBackgroundColorAttributeName];
	else
		[self removeAttributeForKeyFromSelectedRange:NSBackgroundColorAttributeName];
}

- (void)richTextEditorToolbarDidSelectTextForegroundColor:(UIColor *)color
{
	if (color)
		[self applyAttributesToSelectedRange:color forKey:NSForegroundColorAttributeName];
	else
		[self removeAttributeForKeyFromSelectedRange:NSForegroundColorAttributeName];
}

- (void)richTextEditorToolbarDidSelectUnderline
{
    NSDictionary *dictionary = [self typingAttributes];
	NSNumber *existingUnderlineStyle = [dictionary objectForKey:NSUnderlineStyleAttributeName];
	
	if (!existingUnderlineStyle || existingUnderlineStyle.intValue == NSUnderlineStyleNone)
		existingUnderlineStyle = [NSNumber numberWithInteger:NSUnderlineStyleSingle];
	else
		existingUnderlineStyle = [NSNumber numberWithInteger:NSUnderlineStyleNone];
	
	[self applyAttributesToSelectedRange:existingUnderlineStyle forKey:NSUnderlineStyleAttributeName];
}

- (void)richTextEditorToolbarDidSelectStrikeThrough
{
    NSDictionary *dictionary = [self typingAttributes];
	NSNumber *existingUnderlineStyle = [dictionary objectForKey:NSStrikethroughStyleAttributeName];
	
	if (!existingUnderlineStyle || existingUnderlineStyle.intValue == NSUnderlineStyleNone)
		existingUnderlineStyle = [NSNumber numberWithInteger:NSUnderlineStyleSingle];
	else
		existingUnderlineStyle = [NSNumber numberWithInteger:NSUnderlineStyleNone];
	
	[self applyAttributesToSelectedRange:existingUnderlineStyle forKey:NSStrikethroughStyleAttributeName];
}

// try/catch blocks on undo/redo because it doesn't work right with bulleted lists when BULLET_STRING has more than 1 character
- (void)richTextEditorToolbarDidSelectUndo
{
    @try {
        BOOL shouldUseUndoManager = YES;
        if ([self.dataSource respondsToSelector:@selector(handlesUndoRedoForText)])
        {
            if ([self.dataSource handlesUndoRedoForText]) {
                [self.dataSource userPerformedUndo];
                shouldUseUndoManager = NO;
            }
        }
        if (shouldUseUndoManager && [[self undoManager] canUndo])
            [[self undoManager] undo];
    }
    @catch (NSException *e) {
        NSLog(@"[RTE] Couldn't perform undo: %@", [e description]);
        [[self undoManager] removeAllActions];
    }
}

- (void)richTextEditorToolbarDidSelectRedo
{
    @try {
        BOOL shouldUseUndoManager = YES;
        if ([self.dataSource respondsToSelector:@selector(handlesUndoRedoForText)])
        {
            if ([self.dataSource handlesUndoRedoForText]) {
                [self.dataSource userPerformedRedo];
                shouldUseUndoManager = NO;
            }
        }
        if (shouldUseUndoManager && [[self undoManager] canRedo])
            [[self undoManager] redo];
    }
    @catch (NSException *e) {
        NSLog(@"[RTE] Couldn't perform redo: %@", [e description]);
        [[self undoManager] removeAllActions];
    }
}

- (void)richTextEditorToolbarDidSelectDismissKeyboard {
    [self resignFirstResponder];
}

- (void)richTextEditorToolbarDidSelectParagraphIndentation:(ParagraphIndentation)paragraphIndentation
{
    __block NSDictionary *dictionary;
    __block NSMutableParagraphStyle *paragraphStyle;
	[self enumarateThroughParagraphsInRange:self.selectedRange withBlock:^(NSRange paragraphRange){
        dictionary = [self dictionaryAtIndex:paragraphRange.location];
        paragraphStyle = [[dictionary objectForKey:NSParagraphStyleAttributeName] mutableCopy];
		if (!paragraphStyle)
			paragraphStyle = [[NSMutableParagraphStyle alloc] init];

		if (paragraphIndentation == ParagraphIndentationIncrease)
		{
			paragraphStyle.headIndent += self.defaultIndentationSize;
			paragraphStyle.firstLineHeadIndent += self.defaultIndentationSize;
		}
		else if (paragraphIndentation == ParagraphIndentationDecrease)
		{
			paragraphStyle.headIndent -= self.defaultIndentationSize;
			paragraphStyle.firstLineHeadIndent -= self.defaultIndentationSize;
			
			if (paragraphStyle.headIndent < 0)
				paragraphStyle.headIndent = 0; // this is the right cursor placement

			if (paragraphStyle.firstLineHeadIndent < 0)
				paragraphStyle.firstLineHeadIndent = 0; // this affects left cursor placement 
		}
		[self applyAttributes:paragraphStyle forKey:NSParagraphStyleAttributeName atRange:paragraphRange];
	}];
    
    // Following 2 lines allow the user to insta-type after indenting in a bulleted list
    NSRange range = NSMakeRange(self.selectedRange.location+self.selectedRange.length, 0);
    [self setSelectedRange:range];
    
    // Check to see if the current paragraph is blank. If it is, manually get the cursor to move with a weird hack.
    NSRange rangeOfCurrentParagraph = [self.attributedText firstParagraphRangeFromTextRange:self.selectedRange];
	BOOL currParagraphIsBlank = [[self.attributedText.string substringWithRange:rangeOfCurrentParagraph] isEqualToString:@""] ? YES: NO;
    if (currParagraphIsBlank)
    {
        [self setIndentationWithAttributes:dictionary paragraphStyle:paragraphStyle atRange:rangeOfCurrentParagraph];
    }
}

// Manually moves the cursor to the correct location. Ugly work around and weird but it works (at least in iOS 7).
// Basically what I do is add a " " with the correct indentation then delete it. For some reason with that
// and applying that attribute to the current typing attributes it moves the cursor to the right place.
-(void)setIndentationWithAttributes:(NSDictionary*)attributes paragraphStyle:(NSMutableParagraphStyle*)paragraphStyle atRange:(NSRange)range
{
    NSMutableAttributedString *attributedText = [self.attributedText mutableCopy];
    NSMutableAttributedString *space = [[NSMutableAttributedString alloc] initWithString:@" " attributes:attributes];
    [space addAttributes:[NSDictionary dictionaryWithObject:paragraphStyle forKey:NSParagraphStyleAttributeName] range:NSMakeRange(0, 1)];
    [attributedText insertAttributedString:space atIndex:range.location];
    self.attributedText = attributedText;
    [self setSelectedRange:NSMakeRange(range.location, 1)];
    [self applyAttributes:paragraphStyle forKey:NSParagraphStyleAttributeName atRange:NSMakeRange(self.selectedRange.location+self.selectedRange.length-1, 1)];
    [self setSelectedRange:NSMakeRange(range.location, 0)];
    [attributedText deleteCharactersInRange:NSMakeRange(range.location, 1)];
    self.attributedText = attributedText;
    [self applyAttributeToTypingAttribute:paragraphStyle forKey:NSParagraphStyleAttributeName];
}

- (void)richTextEditorToolbarDidSelectParagraphFirstLineHeadIndent
{
	[self enumarateThroughParagraphsInRange:self.selectedRange withBlock:^(NSRange paragraphRange){
		NSDictionary *dictionary = [self dictionaryAtIndex:paragraphRange.location];
		NSMutableParagraphStyle *paragraphStyle = [[dictionary objectForKey:NSParagraphStyleAttributeName] mutableCopy];
		
		if (!paragraphStyle)
			paragraphStyle = [[NSMutableParagraphStyle alloc] init];
		
		if (paragraphStyle.headIndent == paragraphStyle.firstLineHeadIndent)
		{
			paragraphStyle.firstLineHeadIndent += self.defaultIndentationSize;
		}
		else
		{
			paragraphStyle.firstLineHeadIndent = paragraphStyle.headIndent;
		}
		
		[self applyAttributes:paragraphStyle forKey:NSParagraphStyleAttributeName atRange:paragraphRange];
	}];
}

- (void)richTextEditorToolbarDidSelectTextAlignment:(NSTextAlignment)textAlignment
{
	[self enumarateThroughParagraphsInRange:self.selectedRange withBlock:^(NSRange paragraphRange){
		NSDictionary *dictionary = [self dictionaryAtIndex:paragraphRange.location];
		NSMutableParagraphStyle *paragraphStyle = [[dictionary objectForKey:NSParagraphStyleAttributeName] mutableCopy];
		
		if (!paragraphStyle)
			paragraphStyle = [[NSMutableParagraphStyle alloc] init];
		
		paragraphStyle.alignment = textAlignment;
		
		[self applyAttributes:paragraphStyle forKey:NSParagraphStyleAttributeName atRange:paragraphRange];
        [self setIndentationWithAttributes:dictionary paragraphStyle:paragraphStyle atRange:paragraphRange];
	}];
    [self updateToolbarState];
}

- (void)richTextEditorToolbarDidSelectBulletListWithCaller:(id)caller
{
    if (self.currSysVersion < 8.0)
        self.scrollEnabled = NO;
    if (caller == self.toolBar)
        self.userInBulletList = !self.userInBulletList;
	NSRange initialSelectedRange = self.selectedRange;
	NSArray *rangeOfParagraphsInSelectedText = [self.attributedText rangeOfParagraphsFromTextRange:self.selectedRange];
	NSRange rangeOfCurrentParagraph = [self.attributedText firstParagraphRangeFromTextRange:self.selectedRange];
	BOOL firstParagraphHasBullet = ([[[self.attributedText string] substringFromIndex:rangeOfCurrentParagraph.location] hasPrefix:BULLET_STRING]) ? YES: NO;
    
    NSRange rangeOfPreviousParagraph = [self.attributedText firstParagraphRangeFromTextRange:NSMakeRange(rangeOfCurrentParagraph.location-1, 0)];
    NSDictionary *prevParaDict = [self dictionaryAtIndex:rangeOfPreviousParagraph.location];
    NSMutableParagraphStyle *prevParaStyle = [prevParaDict objectForKey:NSParagraphStyleAttributeName];
	
	__block NSInteger rangeOffset = 0;
	
	[self enumarateThroughParagraphsInRange:self.selectedRange withBlock:^(NSRange paragraphRange){
		NSRange range = NSMakeRange(paragraphRange.location + rangeOffset, paragraphRange.length);
		NSMutableAttributedString *currentAttributedString = [self.attributedText mutableCopy];
		NSDictionary *dictionary = [self dictionaryAtIndex:MAX((int)range.location-1, 0)];
		NSMutableParagraphStyle *paragraphStyle = [[dictionary objectForKey:NSParagraphStyleAttributeName] mutableCopy];
		
		if (!paragraphStyle)
			paragraphStyle = [[NSMutableParagraphStyle alloc] init];
		
		BOOL currentParagraphHasBullet = ([[[currentAttributedString string] substringFromIndex:range.location] hasPrefix:BULLET_STRING]) ? YES : NO;
		
		if (firstParagraphHasBullet != currentParagraphHasBullet)
			return;
		if (currentParagraphHasBullet)
		{
            // User hit the bullet button and is in a bulleted list so we should get rid of the bullet
			range = NSMakeRange(range.location, range.length - BULLET_STRING.length);
			
			[currentAttributedString deleteCharactersInRange:NSMakeRange(range.location, BULLET_STRING.length)];
			
			paragraphStyle.firstLineHeadIndent = 0;
			paragraphStyle.headIndent = 0;
			
			rangeOffset = rangeOffset - BULLET_STRING.length;
            self.userInBulletList = NO;
		}
		else
        {
            // We are adding a bullet
			range = NSMakeRange(range.location, range.length + BULLET_STRING.length);
			
			NSMutableAttributedString *bulletAttributedString = [[NSMutableAttributedString alloc] initWithString:BULLET_STRING attributes:nil];
            /* I considered manually removing any bold/italic/underline/strikethrough from the text, but 
             // decided against it. If the user wants bold bullets, let them have bold bullets!
            UIFont *prevFont = [dictionary objectForKey:NSFontAttributeName];
            UIFont *bulletFont = [UIFont fontWithName:[prevFont familyName] size:[prevFont pointSize]];
            NSMutableDictionary *bulletDict = [dictionary mutableCopy];
            [bulletDict setObject:bulletFont forKey:NSFontAttributeName];
            [bulletDict setObject:0 forKey:NSStrikethroughStyleAttributeName];
            [bulletDict setObject:0 forKey:NSUnderlineStyleAttributeName];
            */
            [bulletAttributedString setAttributes:dictionary range:NSMakeRange(0, BULLET_STRING.length)];
			
			[currentAttributedString insertAttributedString:bulletAttributedString atIndex:range.location];
			
			CGSize expectedStringSize = [BULLET_STRING sizeWithAttributes:dictionary];
            
            // See if the previous paragraph has a bullet
            NSString *previousParagraph = [self.attributedText.string substringWithRange:rangeOfPreviousParagraph];
            BOOL doesPrefixWithBullet = [previousParagraph hasPrefix:BULLET_STRING];
            
            // Look at the previous paragraph to see what the firstLineHeadIndent should be for the
            // current bullet
            // if the previous paragraph has a bullet, use that paragraph's indent
            // if not, then use defaultIndentation size
            if (!doesPrefixWithBullet)
                paragraphStyle.firstLineHeadIndent = self.defaultIndentationSize;
            else paragraphStyle.firstLineHeadIndent = prevParaStyle.firstLineHeadIndent;
            
			paragraphStyle.headIndent = expectedStringSize.width;
			
			rangeOffset = rangeOffset + BULLET_STRING.length;
            self.userInBulletList = YES;
		}
        [currentAttributedString addAttribute:NSParagraphStyleAttributeName value:paragraphStyle range:range];
        self.attributedText = currentAttributedString;
		//[self applyAttributes:paragraphStyle forKey:NSParagraphStyleAttributeName atRange:range];
	}];
	
	// If paragraph is empty move cursor to front of bullet, so the user can start typing right away
    NSRange rangeForSelection;
	if (rangeOfParagraphsInSelectedText.count == 1 && rangeOfCurrentParagraph.length == 0)
	{
        rangeForSelection = NSMakeRange(rangeOfCurrentParagraph.location + BULLET_STRING.length, 0);
	}
	else
	{
		if (initialSelectedRange.length == 0)
        {
            rangeForSelection = NSMakeRange(initialSelectedRange.location+rangeOffset, 0);
		}
		else
        {
			NSRange fullRange = [self fullRangeFromArrayOfParagraphRanges:rangeOfParagraphsInSelectedText];
            rangeForSelection = NSMakeRange(fullRange.location, fullRange.length+rangeOffset);
		}
    }
    //NSLog(@"[RTE] Range for end of bullet: %lu, %lu", (unsigned long)rangeForSelection.location, (unsigned long)rangeForSelection.length);
    if (self.currSysVersion < 8.0)
        self.scrollEnabled = YES;
   [self setSelectedRange:rangeForSelection];
}

- (void)richTextEditorToolbarDidSelectTextAttachment:(UIImage *)textAttachment
{
	NSTextAttachment *attachment = [[NSTextAttachment alloc] init];
	[attachment setImage:textAttachment];
	NSAttributedString *attributedStringAttachment = [NSAttributedString attributedStringWithAttachment:attachment];
	
	NSDictionary *previousAttributes = [self dictionaryAtIndex:self.selectedRange.location];
	
	NSMutableAttributedString *attributedString = [self.attributedText mutableCopy];
	[attributedString insertAttributedString:attributedStringAttachment atIndex:self.selectedRange.location];
	[attributedString addAttributes:previousAttributes range:NSMakeRange(self.selectedRange.location, 1)];
	self.attributedText = attributedString;
}

- (UIViewController <RichTextEditorColorPicker> *)colorPickerForRichTextEditorToolbarWithAction:(RichTextEditorColorPickerAction)action
{
	if ([self.dataSource respondsToSelector:@selector(colorPickerForRichTextEditor:withAction:)]) { // changed "forAction" to "withAction"
		return [self.dataSource colorPickerForRichTextEditor:self withAction:action];
    }
	
	return nil;
}

- (UIViewController <RichTextEditorFontPicker> *)fontPickerForRichTextEditorToolbar
{
	if ([self.dataSource respondsToSelector:@selector(fontPickerForRichTextEditor:)])
		return [self.dataSource fontPickerForRichTextEditor:self];
	
	return nil;
}

- (UIViewController <RichTextEditorFontSizePicker> *)fontSizePickerForRichTextEditorToolbar
{
	if ([self.dataSource respondsToSelector:@selector(fontSizePickerForRichTextEditor:)])
		return [self.dataSource fontSizePickerForRichTextEditor:self];
	
	return nil;
}

#pragma mark - Private Methods -

- (CGRect)frameOfTextAtRange:(NSRange)range
{
	UITextRange *selectionRange = [self selectedTextRange];
	NSArray *selectionRects = [self selectionRectsForRange:selectionRange];
	CGRect completeRect = CGRectNull;
	
	for (UITextSelectionRect *selectionRect in selectionRects)
	{
		completeRect = (CGRectIsNull(completeRect))
        ? selectionRect.rect
        : CGRectUnion(completeRect,selectionRect.rect);
	}
	
	return completeRect;
}

- (void)enumarateThroughParagraphsInRange:(NSRange)range withBlock:(void (^)(NSRange paragraphRange))block
{
	NSArray *rangeOfParagraphsInSelectedText = [self.attributedText rangeOfParagraphsFromTextRange:self.selectedRange];
	
	for (int i=0 ; i<rangeOfParagraphsInSelectedText.count ; i++)
	{
		NSValue *value = [rangeOfParagraphsInSelectedText objectAtIndex:i];
		NSRange paragraphRange = [value rangeValue];
		block(paragraphRange);
	}
	
	NSRange fullRange = [self fullRangeFromArrayOfParagraphRanges:rangeOfParagraphsInSelectedText];
	[self setSelectedRange:fullRange];
}

- (void)updateToolbarState
{
	// There is a bug in iOS6 that causes a crash when accessing typingAttribute on an empty text
	if (!SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(@"7.0") && ![self hasText])
		return;
	
	// If no text exists or typing attributes is in progress update toolbar using typing attributes instead of selected text
	if (self.typingAttributesInProgress || ![self hasText])
	{
		[self.toolBar updateStateWithAttributes:self.typingAttributes];
	}
	else
	{
		NSInteger location = 0;
		
		if (self.selectedRange.location != NSNotFound)
		{
			location = (self.selectedRange.length == 0) ? MAX((int)self.selectedRange.location-1, 0)
                                                        : (int)self.selectedRange.location;
		}
		
		NSDictionary *attributes = [self.attributedText attributesAtIndex:location effectiveRange:nil];
		[self.toolBar updateStateWithAttributes:attributes];
	}
}

- (NSRange)fullRangeFromArrayOfParagraphRanges:(NSArray *)paragraphRanges
{
	if (!paragraphRanges.count)
		return NSMakeRange(0, 0);
	
	NSRange firstRange = [[paragraphRanges objectAtIndex:0] rangeValue];
	NSRange lastRange = [[paragraphRanges lastObject] rangeValue];
	return NSMakeRange(firstRange.location, lastRange.location + lastRange.length - firstRange.location);
}

- (UIFont *)fontAtIndex:(NSInteger)index
{
    return [[self dictionaryAtIndex:index] objectForKey:NSFontAttributeName];
}

- (NSDictionary *)dictionaryAtIndex:(NSInteger)index
{
    if (![self hasText] || index == self.attributedText.string.length)
        return self.typingAttributes; // end of string, use whatever we're currently using
    else
        return [self.attributedText attributesAtIndex:index effectiveRange:nil];
}

- (void)applyAttributeToTypingAttribute:(id)attribute forKey:(NSString *)key
{
	NSMutableDictionary *dictionary = [self.typingAttributes mutableCopy];
	[dictionary setObject:attribute forKey:key];
	[self setTypingAttributes:dictionary];
}

- (void)applyAttributes:(id)attribute forKey:(NSString *)key atRange:(NSRange)range
{
	// If any text selected apply attributes to text
	if (range.length > 0)
	{
		NSMutableAttributedString *attributedString = [self.attributedText mutableCopy];
		
        // Workaround for when there is only one paragraph,
		// sometimes the attributedString is actually longer by one then the displayed text,
		// and this results in not being able to set to lef align anymore.
        if (range.length == attributedString.length-1 && range.length == self.text.length)
            ++range.length;
        
		[attributedString addAttributes:[NSDictionary dictionaryWithObject:attribute forKey:key] range:range];
		
		[self setAttributedText:attributedString];
        if (!SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(@"8.0"))
            [self setSelectedRange:range];
	}
	// If no text is selected apply attributes to typingAttribute
	else
	{
		self.typingAttributesInProgress = YES;
		[self applyAttributeToTypingAttribute:attribute forKey:key];
	}
	
	[self updateToolbarState];
}

- (void)removeAttributeForKey:(NSString *)key atRange:(NSRange)range
{
	NSRange initialRange = self.selectedRange;
	
	NSMutableAttributedString *attributedString = [self.attributedText mutableCopy];
	[attributedString removeAttribute:key range:range];
	self.attributedText = attributedString;
	
	[self setSelectedRange:initialRange];
}

- (void)removeAttributeForKeyFromSelectedRange:(NSString *)key
{
	[self removeAttributeForKey:key atRange:self.selectedRange];
}

- (void)applyAttributesToSelectedRange:(id)attribute forKey:(NSString *)key
{
	[self applyAttributes:attribute forKey:key atRange:self.selectedRange];
}

- (void)applyFontAttributesToSelectedRangeWithBoldTrait:(NSNumber *)isBold italicTrait:(NSNumber *)isItalic fontName:(NSString *)fontName fontSize:(NSNumber *)fontSize
{
	[self applyFontAttributesWithBoldTrait:isBold italicTrait:isItalic fontName:fontName fontSize:fontSize toTextAtRange:self.selectedRange];
}

- (void)applyFontAttributesWithBoldTrait:(NSNumber *)isBold italicTrait:(NSNumber *)isItalic fontName:(NSString *)fontName fontSize:(NSNumber *)fontSize toTextAtRange:(NSRange)range
{
	// If any text selected apply attributes to text
	if (range.length > 0)
	{
		NSMutableAttributedString *attributedString = [self.attributedText mutableCopy];
		
		[attributedString beginEditing];
		[attributedString enumerateAttributesInRange:range
											 options:NSAttributedStringEnumerationLongestEffectiveRangeNotRequired
										  usingBlock:^(NSDictionary *dictionary, NSRange range, BOOL *stop){
											  
											  UIFont *newFont = [self fontwithBoldTrait:isBold
																			italicTrait:isItalic
																			   fontName:fontName
																			   fontSize:fontSize
																		 fromDictionary:dictionary];
											  
											  if (newFont)
												  [attributedString addAttributes:[NSDictionary dictionaryWithObject:newFont forKey:NSFontAttributeName] range:range];
										  }];
		[attributedString endEditing];
		self.attributedText = attributedString;
		
		[self setSelectedRange:range];
	}
	// If no text is selected apply attributes to typingAttribute
	else
	{
		self.typingAttributesInProgress = YES;
		
		UIFont *newFont = [self fontwithBoldTrait:isBold
									  italicTrait:isItalic
										 fontName:fontName
										 fontSize:fontSize
								   fromDictionary:self.typingAttributes];
		if (newFont)
            [self applyAttributeToTypingAttribute:newFont forKey:NSFontAttributeName];
	}
	
	[self updateToolbarState];
}

// TODO: Fix this function. You can't create a font that isn't bold from a dictionary that has a bold attribute currently, since if you send isBold 0 [nil], it'll use the dictionary, which is bold!
// In other words, this function has logical errors.
// Returns a font with given attributes. For any missing parameter takes the attribute from a given dictionary
- (UIFont *)fontwithBoldTrait:(NSNumber *)isBold italicTrait:(NSNumber *)isItalic fontName:(NSString *)fontName fontSize:(NSNumber *)fontSize fromDictionary:(NSDictionary *)dictionary
{
	UIFont *newFont = nil;
	UIFont *font = [dictionary objectForKey:NSFontAttributeName];
	BOOL newBold = (isBold) ? isBold.intValue : [font isBold];
	BOOL newItalic = (isItalic) ? isItalic.intValue : [font isItalic];
	CGFloat newFontSize = (fontSize) ? fontSize.floatValue : font.pointSize;
	
	if (fontName)
	{
		newFont = [UIFont fontWithName:fontName size:newFontSize boldTrait:newBold italicTrait:newItalic];
	}
	else
	{
		newFont = [font fontWithBoldTrait:newBold italicTrait:newItalic andSize:newFontSize];
	}
	
	return newFont;
}

- (CGRect)currentScreenBoundsDependOnOrientation
{
    CGRect screenBounds = [UIScreen mainScreen].bounds ;
    CGFloat width = CGRectGetWidth(screenBounds)  ;
    CGFloat height = CGRectGetHeight(screenBounds) ;
    UIInterfaceOrientation interfaceOrientation = [UIApplication sharedApplication].statusBarOrientation;
	
    if (UIInterfaceOrientationIsPortrait(interfaceOrientation))
	{
        screenBounds.size = CGSizeMake(width, height);
    }
	else if (UIInterfaceOrientationIsLandscape(interfaceOrientation))
	{
        screenBounds.size = CGSizeMake(height, width);
    }
	
    return screenBounds ;
}

- (void)applyBulletListIfApplicable
{
	NSRange rangeOfCurrentParagraph = [self.attributedText firstParagraphRangeFromTextRange:self.selectedRange];
    if (rangeOfCurrentParagraph.location == 0)
        return; // there isn't a previous paragraph, so forget it. The user isn't in a bulleted list.
	NSRange rangeOfPreviousParagraph = [self.attributedText firstParagraphRangeFromTextRange:NSMakeRange(rangeOfCurrentParagraph.location-1, 0)];
    //NSLog(@"[RTE] Is the user in the bullet list? %d", self.userInBulletList);
    if (!self.userInBulletList) { // fixes issue with backspacing into bullet list adding a bullet
		BOOL currentParagraphHasBullet = ([[self.attributedText.string substringFromIndex:rangeOfCurrentParagraph.location] hasPrefix:BULLET_STRING]) ? YES : NO;
		BOOL previousParagraphHasBullet = ([[self.attributedText.string substringFromIndex:rangeOfPreviousParagraph.location] hasPrefix:BULLET_STRING]) ? YES : NO;
        BOOL isCurrParaBlank = [[self.attributedText.string substringWithRange:rangeOfCurrentParagraph] isEqualToString:@""];
        // if we don't check to see if the current paragraph is blank, bad bugs happen with
        // the current paragraph where the selected range doesn't let the user type O_o
        if (previousParagraphHasBullet && !currentParagraphHasBullet && isCurrParaBlank) {
            // Fix the indentation. Here is the use case for this code:
            /*
             ---
                • bullet
             
             |
             ---
             Where | is the cursor on a blank line. User hits backspace. Without fixing the 
             indentation, the cursor ends up indented at the same indentation as the bullet.
             */
            NSDictionary *dictionary = [self dictionaryAtIndex:rangeOfCurrentParagraph.location];
            NSMutableParagraphStyle *paragraphStyle = [[dictionary objectForKey:NSParagraphStyleAttributeName] mutableCopy];
            paragraphStyle.firstLineHeadIndent = 0;
            paragraphStyle.headIndent = 0;
            [self applyAttributes:paragraphStyle forKey:NSParagraphStyleAttributeName atRange:rangeOfCurrentParagraph];
        }
        return;
    }
	if (rangeOfCurrentParagraph.length != 0)
		return;
    if ([[self.attributedText.string substringFromIndex:rangeOfPreviousParagraph.location] hasPrefix:BULLET_STRING])
        [self richTextEditorToolbarDidSelectBulletListWithCaller:self];
}

- (void)deleteBulletListWhenApplicable
{
	NSRange range = self.selectedRange;
	// TODO: Clean up this code since a lot of it is "repeated"
	if (range.location > 0)
	{
        NSString *checkString = BULLET_STRING;
        if ([checkString length] > 1) // chop off last letter and use that
            checkString = [checkString substringToIndex:[checkString length]-1];
        //else return;
        NSUInteger checkStringLength = [checkString length];
        if (![self.attributedText.string isEqualToString:BULLET_STRING]) {
            if (((int)(range.location-checkStringLength) >= 0 &&
                 [[self.attributedText.string substringFromIndex:range.location-checkStringLength] hasPrefix:checkString])) {
                NSLog(@"[RTE] Getting rid of a bullet due to backspace while in empty bullet paragraph.");
                // Get rid of bullet string
                NSMutableAttributedString *mutableAttributedString = [self.attributedText mutableCopy];
                [mutableAttributedString deleteCharactersInRange:NSMakeRange(range.location-checkStringLength, checkStringLength)];
                self.attributedText = mutableAttributedString;
                NSRange newRange = NSMakeRange(range.location-checkStringLength, 0);
                [self setSelectedRange:newRange];
                
                // Get rid of bullet indentation
                NSRange rangeOfParagraph = [self.attributedText firstParagraphRangeFromTextRange:newRange];
                NSDictionary *dictionary = [self dictionaryAtIndex:rangeOfParagraph.location];
                NSMutableParagraphStyle *paragraphStyle = [[dictionary objectForKey:NSParagraphStyleAttributeName] mutableCopy];
                paragraphStyle.firstLineHeadIndent = 0;
                paragraphStyle.headIndent = 0;
                [self applyAttributes:paragraphStyle forKey:NSParagraphStyleAttributeName atRange:rangeOfParagraph];
                self.userInBulletList = NO;
            }
            else {
                // User may be needing to get out of a bulleted list due to hitting enter (return)
                NSRange rangeOfCurrentParagraph = [self.attributedText firstParagraphRangeFromTextRange:self.selectedRange];
                NSInteger prevParaLocation = rangeOfCurrentParagraph.location-1;
                if (prevParaLocation >= 0) {
                    NSRange rangeOfPreviousParagraph = [self.attributedText firstParagraphRangeFromTextRange:NSMakeRange(rangeOfCurrentParagraph.location-1, 0)];
                    // If the following if statement is true, the user hit enter on a blank bullet list
                    // Basically, there is now a bullet \t \n bullet \t that we need to delete
                    // Since it gets here AFTER it adds a new bullet
                    if ([[self.attributedText.string substringWithRange:rangeOfPreviousParagraph] hasSuffix:BULLET_STRING]) {
                        //NSLog(@"[RTE] Getting rid of bullets due to user hitting enter.");
                        NSMutableAttributedString *mutableAttributedString = [self.attributedText mutableCopy];
                        NSRange rangeToDelete = NSMakeRange(rangeOfPreviousParagraph.location, rangeOfPreviousParagraph.length+rangeOfCurrentParagraph.length+1);
                        [mutableAttributedString deleteCharactersInRange:rangeToDelete];
                        self.attributedText = mutableAttributedString;
                        
                        NSRange newRange = NSMakeRange(rangeOfPreviousParagraph.location, 0);
                        [self setSelectedRange:newRange];
                        
                        // Get rid of bullet indentation
                        NSRange rangeOfParagraph = [self.attributedText firstParagraphRangeFromTextRange:newRange];
                        NSDictionary *dictionary = [self dictionaryAtIndex:newRange.location];
                        NSMutableParagraphStyle *paragraphStyle = [[dictionary objectForKey:NSParagraphStyleAttributeName] mutableCopy];
                        paragraphStyle.firstLineHeadIndent = 0;
                        paragraphStyle.headIndent = 0;
                        [self applyAttributes:paragraphStyle forKey:NSParagraphStyleAttributeName atRange:rangeOfParagraph];
                        self.userInBulletList = NO;
                    }
                }                
            }
        }
	}
}

#pragma mark - RichTextEditorToolbarDataSource Methods -

- (NSArray *)fontFamilySelectionForRichTextEditorToolbar
{
	if (self.dataSource && [self.dataSource respondsToSelector:@selector(fontFamilySelectionForRichTextEditor:)])
	{
		return [self.dataSource fontFamilySelectionForRichTextEditor:self];
	}
	
	return nil;
}

- (NSArray *)fontSizeSelectionForRichTextEditorToolbar
{
	if (self.dataSource && [self.dataSource respondsToSelector:@selector(fontSizeSelectionForRichTextEditor:)])
	{
		return [self.dataSource fontSizeSelectionForRichTextEditor:self];
	}
	
	return nil;
}

- (RichTextEditorToolbarPresentationStyle)presentationStyleForRichTextEditorToolbar
{
	if (self.dataSource && [self.dataSource respondsToSelector:@selector(presentationStyleForRichTextEditor:)])
	{
		return [self.dataSource presentationStyleForRichTextEditor:self];
	}
    
	return (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad)
    ? RichTextEditorToolbarPresentationStylePopover
    : RichTextEditorToolbarPresentationStyleModal;
}

- (UIModalPresentationStyle)modalPresentationStyleForRichTextEditorToolbar
{
	if (self.dataSource && [self.dataSource respondsToSelector:@selector(modalPresentationStyleForRichTextEditor:)])
	{
		return [self.dataSource modalPresentationStyleForRichTextEditor:self];
	}
	
	return (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad)
    ? UIModalPresentationFormSheet
    : UIModalPresentationFullScreen;
}

- (UIModalTransitionStyle)modalTransitionStyleForRichTextEditorToolbar
{
	if (self.dataSource && [self.dataSource respondsToSelector:@selector(modalTransitionStyleForRichTextEditor:)])
	{
		return [self.dataSource modalTransitionStyleForRichTextEditor:self];
	}
	
	return UIModalTransitionStyleCoverVertical;
}

- (RichTextEditorFeature)featuresEnabledForRichTextEditorToolbar
{
	if (self.dataSource && [self.dataSource respondsToSelector:@selector(featuresEnabledForRichTextEditor:)])
	{
		return [self.dataSource featuresEnabledForRichTextEditor:self];
	}
	
	return RichTextEditorFeatureAll;
}

- (UIViewController *)firstAvailableViewControllerForRichTextEditorToolbar
{
	return [self firstAvailableViewController];
}

#pragma mark - Keyboard Shortcuts

- (NSArray *)keyCommands {
    return @[[UIKeyCommand keyCommandWithInput:@"b" modifierFlags:UIKeyModifierCommand action:@selector(keyboardKeyPressed:)],
             [UIKeyCommand keyCommandWithInput:@"i" modifierFlags:UIKeyModifierCommand action:@selector(keyboardKeyPressed:)],
             [UIKeyCommand keyCommandWithInput:@"u" modifierFlags:UIKeyModifierCommand action:@selector(keyboardKeyPressed:)]
             ];
}

- (void)keyboardKeyPressed:(UIKeyCommand*)keyPressed {
    switch ([keyPressed.input UTF8String][0]) {
        case 'b':
            [self richTextEditorToolbarDidSelectBold];
            break;
        case 'i':
            [self richTextEditorToolbarDidSelectItalic];
            break;
        case 'u':
            [self richTextEditorToolbarDidSelectUnderline];
            break;
        default:
            break;
    }
}

@end
